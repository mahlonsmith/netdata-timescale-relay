# vim: set et nosta sw=4 ts=4 :
#
# Copyright (c) 2018, Mahlon E. Smith <mahlon@martini.nu>
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
    os,
    parseopt2,
    posix,
    strutils,
    tables,
    terminal,
    times


const
    VERSION = "v0.1.0"
    USAGE = """
./netdata_tsrelay [-q][-v][-h] --dbopts="[PostgreSQL connection string]" --listen-port=14866 --listen-addr=0.0.0.0

  -q: Quiet mode.  No output at all.  Ignored if -d is supplied.
  -d: Debug: Show incoming and parsed data.
  -v: Display version number.
  -T: Change the destination table name from the default 'netdata'.
  -t: Alter the maximum time (in ms) an open socket waits for data.  Default: 500ms.
  -h: Help.  You're lookin' at it.

The default connection string is:
  "host=localhost port=5432 dbname=netdata user=netdata application_name=netdata-tsrelay"
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
        listen_port: int     # The port to listen for incoming connections.
        listen_addr: string  # The IP address listen for incoming connections.  Defaults to inaddr_any.
        verbose:     bool    # Be informative
        debug:       bool    # Spew out raw data
        insertsql:   string  # The SQL insert string after interpolating the table name.
        timeout:     int     # How long to block, waiting on connection data.

# Global configuration
var conf: Config


proc hl( msg: string, fg: ForegroundColor, bright=false ): string =
    ## Quick wrapper for color formatting a string, since the 'terminal'
    ## module only deals with stdout directly.
    if not isatty(stdout): return msg

    var color: BiggestInt = ord( fg )
    if bright: inc( color, 60 )
    result = "\e[" & $color & 'm' & msg & "\e[0m"


proc fetch_data( client: Socket ): string =
    ## Netdata JSON backend doesn't send a length, so we read line by
    ## line and wait for stream timeout to determine a "sample".
    var buf: string = nil
    try:
        result = client.recv_line( timeout=conf.timeout )
        if result != "" and not result.is_nil: result = result & "\n"
        while buf != "":
            buf = client.recv_line( timeout=conf.timeout )
            if buf != "" and not buf.is_nil: result = result & buf & "\n"
    except TimeoutError:
        discard


proc parse_data( data: string ): seq[ JsonNode ] =
    ## Given a raw +data+ string, parse JSON and return a sequence
    ## of JSON samples. Netdata can buffer multiple samples in one batch.
    result = @[]
    if data == "" or data.is_nil: return

    # Hash of sample timeperiods to pivoted json data
    var pivoted_data = init_table[ BiggestInt, JsonNode ]()

    for sample in split_lines( data ):
        if sample == "" or sample.is_nil: continue
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
            let key = parsed["timestamp"].get_num

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


proc write_to_database( samples: seq[ JsonNode ] ): void =
    ## Given a sequence of json samples, write them to database.
    if samples.len == 0: return

    let db = open( "", "", "", conf.dbopts )

    try:
        db.exec sql( "BEGIN" )
        for sample in samples:
            var
                timestamp = sample[ "timestamp" ].get_num
                host = sample[ "hostname" ].get_str
            sample.delete( "timestamp" )
            sample.delete( "hostname" )
            db.exec sql( conf.insertsql ), timestamp, host, sample
        db.exec sql( "COMMIT" )
    except:
        let
            e = getCurrentException()
            msg = getCurrentExceptionMsg()
        echo "Got exception ", repr(e), " while writing to DB: ", msg
        discard

    db.close


proc process( client: Socket, address: string ): void =
    ## Do the work for a connected client within child process.
    let t0 = cpu_time()
    var raw_data = client.fetch_data

    # Done with the socket, netdata will automatically
    # reconnect.  Save local resources/file descriptors
    # by closing after the send is considered complete.
    #
    try:
        client.close
    except OSError:
        return

    # Pivot the parsed data to a single JSON blob per sample time.
    var samples = parse_data( raw_data )
    write_to_database( samples )

    if conf.verbose:
        echo(
            hl( $(epochTime().to_int), fgMagenta, bright=true ),
            " ",
            hl( $(samples.len), fgWhite, bright=true ),
            " sample(s) parsed from ",
            address.hl( fgYellow, bright=true ),
            " in ", hl($( round(cpu_time() - t0, 3) ), fgWhite, bright=true), " seconds."
            # " ", hl($(round((get_occupied_mem()/1024/1024),1)), fgWhite, bright=true), "MB memory used."
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
        var
            client  = new Socket
            address = ""

        # Block, waiting for new connections.
        server.acceptAddr( client, address )

        if fork() == 0:
            server.close
            client.process( address )
            quit( 0 )

        client.close
        when defined( testing ): dumpNumberOfInstances()


proc parse_cmdline: Config =
    ## Populate the config object with the user's preferences.

    # Config object defaults.
    #
    result = Config(
        dbopts: "host=localhost port=5432 dbname=netdata user=netdata application_name=netdata-tsrelay",
        dbtable: "netdata",
        listen_port: 14866,
        listen_addr: "0.0.0.0",
        verbose: true,
        debug: false,
        timeout: 500,
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
                of "dbopts": result.dbopts = val

                of "listen-addr", "a": result.listen_addr = val
                of "listen-port", "p": result.listen_port = val.parse_int

                else: discard

        of cmdEnd: assert( false ) # shouldn't reach here ever


when isMainModule:
    system.addQuitProc( resetAttributes )
    conf = parse_cmdline()
    if conf.debug: echo hl( $conf, fgYellow )
    serverloop( conf )

