# vim: set et nosta sw=4 ts=4 :
#
# Copyright (c) 2018-2020, Mahlon E. Smith <mahlon@martini.nu>
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#
#     * Neither the name of Mahlon E. Smith nor the names of his
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE REGENTS AND CONTRIBUTORS BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


import
    db_postgres,
    json,
    math,
    nativesockets,
    net,
    parseopt,
    posix,
    strutils,
    strformat,
    tables,
    terminal,
    times


const
    VERSION = "v0.3.0"
    USAGE = """
./netdata_tsrelay [-adDhopqtTv]

  -a --listen-addr:
    The outbound IP address to listen for netdata streams.

  -d --debug:
    Debug: Show incoming and parsed data.

  -D --dropconn:
    Drop the persistent socket to netdata between samples to conserve
    local resources.  This may be helpful with a large number of clients.
    Defaults to false.

  -h --help:
    Help.  You're lookin' at it.

  -o --dbopts:
    The PostgreSQL connection string parameters.
    The default connection string is:
      "host=localhost dbname=netdata application_name=netdata-tsrelay"

  -p --listen-port:
    Change the listening port from the default (14866).

  -P --persistent:
    Don't disconnect from the database between samples.  This may be
    more efficient with a small number of clients, when not using a
    pooler, or with a very high sample size/rate.  Defaults to false.

  -q --quiet:
    Quiet mode.  No output at all.  Ignored if -d is supplied.

  -T --dbtable:
    Change the destination table name from the default (netdata).

  -t --timeout:
    Alter the maximum time (in ms) an open socket waits for data
    before processing the sample.  Default: 500ms.

  -v --verbose:
    Display version number.

    """
    INSERT_SQL = """
    INSERT INTO $1
        ( time, host, metrics )
    VALUES
        ( 'epoch'::timestamptz + ? * '1 second'::interval, ?, ? )
    """


type
    Config = object of RootObj
        dbopts:      string  # The postgresql connection parameters.  (See https://www.postgresql.org/docs/current/static/libpq-connect.html)
        dbtable:     string  # The name of the table to write to.
        dropconn:    bool    # Close the TCP connection between samples.
        persistent:  bool    # Don't close the database handle between samples.
        listen_port: int     # The port to listen for incoming connections.
        listen_addr: string  # The IP address listen for incoming connections.  Defaults to inaddr_any.
        verbose:     bool    # Be informative
        debug:       bool    # Spew out raw data
        insertsql:   string  # The SQL insert string after interpolating the table name.
        timeout:     int     # How long to block, waiting on connection data.


type
    NetdataClient = ref object
        sock: Socket    # The raw socket fd
        address: string # The remote IP address
        db: DbConn      # An optionally persistent database handle


# Global configuration
var conf: Config


proc hl( msg: string, fg: ForegroundColor, bright=false ): string =
    ## Quick wrapper for color formatting a string, since the 'terminal'
    ## module only deals with stdout directly.
    if not isatty(stdout): return msg

    var color: BiggestInt = ord( fg )
    if bright: inc( color, 60 )
    result = "\e[" & $color & 'm' & msg & "\e[0m"


proc fetch_data( client: NetdataClient ): string =
    ## Netdata JSON backend doesn't send a length nor a separator
    ## between samples, so we read line by line and wait for stream
    ## timeout to determine what constitutes a sample.
    var buf = ""
    while true:
        try:
            client.sock.readline( buf, timeout=conf.timeout )
            if buf == "":
                if conf.debug: echo "Client {client.address} closed socket.".fmt.hl( fgRed, bright=true )
                quit( 1 )

            result = result & buf & "\n"

        except OSError:
            quit( 1 )
        except TimeoutError:
            if result == "": continue 
            return


proc parse_data( data: string ): seq[ JsonNode ] =
    ## Given a raw +data+ string, parse JSON and return a sequence
    ## of JSON samples. Netdata can buffer multiple samples in one batch.
    result = @[]
    if data == "": return

    # Hash of sample timeperiods to pivoted json data
    var pivoted_data = init_table[ BiggestInt, JsonNode ]()

    for sample in split_lines( data ):
        if sample == "": continue
        if conf.debug: echo sample.hl( fgBlack, bright=true )

        var parsed: JsonNode
        try:
            parsed = sample.parse_json
        except JsonParsingError:
            if conf.debug: echo hl( "Unable to parse sample line: " & sample.hl(fgRed, bright=true), fgRed )
            continue
        if parsed.kind != JObject: return

        # Create or use existing Json object for modded data.
        #
        var pivot: JsonNode
        try:
            let key = parsed[ "timestamp" ].get_int

            if pivoted_data.has_key( key ):
                pivot = pivoted_data[ key ]
            else:
                pivot = newJObject()
                pivoted_data[ key ] = pivot

            var name = parsed[ "chart_id" ].get_str & "." & parsed[ "id" ].get_str
            pivot[ "hostname" ] = parsed[ "hostname" ]
            pivot[ "timestamp" ] = parsed[ "timestamp" ]
            pivot[ name ] = parsed[ "value" ]
        except:
            continue

    for timestamp, sample in pivoted_data:
        result.add( sample )


proc write_to_database( client: NetdataClient, samples: seq[ JsonNode ] ): void =
    ## Given a sequence of json samples, write them to database.
    if samples.len == 0: return

    if client.db.isNil:
        client.db = open( "", "", "", conf.dbopts )

    try:
        client.db.exec sql( "BEGIN" )
        for sample in samples:
            var
                timestamp = sample[ "timestamp" ].get_int
                host = sample[ "hostname" ].get_str.to_lowerascii
            sample.delete( "timestamp" )
            sample.delete( "hostname" )
            client.db.exec sql( conf.insertsql ), timestamp, host, sample
        client.db.exec sql( "COMMIT" )
    except:
        let
            e = getCurrentException()
            msg = getCurrentExceptionMsg()
        echo "Got exception ", repr(e), " while writing to DB: ", msg
        discard

    if not conf.persistent:
        client.db.close
        client.db = nil


proc process( client: NetdataClient ): void =
    ## Do the work for a connected client within child process.
    let t0 = cpu_time()
    var raw_data = client.fetch_data

    # Done with the socket, netdata will automatically
    # reconnect.  Save local resources/file descriptors
    # by closing after the send is considered complete.
    #
    if conf.dropconn:
        try:
            client.sock.close
        except OSError:
            return

    # Pivot the parsed data to a single JSON blob per sample time.
    var samples = parse_data( raw_data )
    client.write_to_database( samples )

    if conf.verbose:
        let cputime = cpu_time() - t0
        echo(
            hl( $(epochTime().to_int), fgMagenta, bright=true ),
            " ",
            hl( $(samples.len), fgWhite, bright=true ),
            " sample(s) parsed from ",
            client.address.hl( fgYellow, bright=true ),
            " in ", hl( "{cputime:<2.3f}".fmt, fgWhite, bright=true), " seconds."
        )


proc serverloop( conf: Config ): void =
    ## Open a database connection, bind to the listening socket,
    ## and start serving incoming netdata streams.
    let db = open( "", "", "", conf.dbopts )
    db.close
    if conf.verbose: echo( "Successfully tested connection to the backend database.".hl( fgGreen ) )

    # Ensure children are properly reaped.
    #
    var sa: Sigaction
    sa.sa_handler = SIG_IGN
    discard sigaction( SIGCHLD, sa )

    # Setup listening socket.
    #
    var server = newSocket()
    server.set_sock_opt( OptReuseAddr, true )
    server.bind_addr( Port(conf.listen_port), conf.listen_addr )
    server.listen()

    if conf.verbose:
        echo(
            "Listening for incoming connections on ".hl( fgGreen, bright=true ),
            hl( (if conf.listen_addr == "0.0.0.0": "*" else: conf.listen_addr) , fgBlue, bright=true ),
            ":",
            hl( $conf.listen_port, fgBlue, bright=true ),
        )
        echo ""

    # Wait for incoming connections, fork for each client.
    #
    while true:
        let client = NetdataClient.new
        client.sock = Socket.new

        # Block, waiting for new connections.
        server.acceptAddr( client.sock, client.address )

        if fork() == 0:
            server.close
            if conf.dropconn:
                # "one shot" mode.
                client.process
                quit( 0 )
            else:
                # Keep the connection to netdata open.
                while true: client.process

        client.sock.close
        when defined( testing ): dumpNumberOfInstances()


proc parse_cmdline: Config =
    ## Populate the config object with the user's preferences.

    # Config object defaults.
    #
    result = Config(
        dbopts: "host=localhost dbname=netdata application_name=netdata-tsrelay",
        dbtable: "netdata",
        dropconn: false,
        listen_port: 14866,
        listen_addr: "0.0.0.0",
        verbose: true,
        debug: false,
        timeout: 500,
        persistent: false,
        insertsql: INSERT_SQL % [ "netdata" ]
    )

    # always set debug mode if development build.
    result.debug = defined( testing )

    for kind, key, val in getopt():
        case kind

        of cmdArgument:
            discard

        of cmdLongOption, cmdShortOption:
            case key
                of "debug", "d":
                    result.debug = true

                of "dropconn", "D":
                    if result.persistent:
                        echo "Dropping TCP sockets are incompatible with persistent database connections."
                        quit( 1 )
                    result.dropconn = true

                of "help", "h":
                    echo USAGE
                    quit( 0 )

                of "quiet", "q":
                    result.verbose = false

                of "version", "v":
                    echo hl( "netdata_tsrelay " & VERSION, fgWhite, bright=true )
                    quit( 0 )

                of "timeout", "t": result.timeout = val.parse_int

                of "dbtable", "T":
                    result.insertsql = INSERT_SQL % [ val ]
                of "dbopts", "o": result.dbopts = val

                of "listen-addr", "a": result.listen_addr = val
                of "listen-port", "p": result.listen_port = val.parse_int

                of "persistent", "P":
                    if result.dropconn:
                        echo "Persistent database connections are incompatible with dropping TCP sockets."
                        quit( 1 )
                    result.persistent = true

                else: discard

        of cmdEnd: assert( false ) # shouldn't reach here ever


when isMainModule:
    system.addQuitProc( resetAttributes )
    conf = parse_cmdline()
    if conf.debug: echo hl( $conf, fgYellow )
    serverloop( conf )

