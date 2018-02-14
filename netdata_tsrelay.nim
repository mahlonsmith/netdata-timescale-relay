# vim: set et nosta sw=4 ts=4 ft=nim : 
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
    strutils,
    tables,
    terminal,
    times,
    threadpool


const
    VERSION = "v0.1.0"
    USAGE = """
./netdata_tsrelay [-q][-v][-h] --dbopts="[PostgreSQL connection string]" --listen-port=14866 --listen-addr=0.0.0.0

  -q: Quiet mode.  No output at all.  Ignored if -d is supplied.
  -c: Suppress ANSI color output.
  -d: Debug: Show incoming and parsed data.
  -v: Display version number.
  -h: Help.  You're lookin' at it.

The default connection string is:
  "host=localhost port=5432 dbname=netdata user=netdata application_name=netdata-tsrelay"
    """
    INSERT_SQL = """
    INSERT INTO netdata
        ( time, host, metrics )
    VALUES
        ( 'epoch'::timestamptz + ? * '1 second'::interval, ?, ? )
    """


type
    Config = object of RootObj
        dbopts:      string  # The postgresql connection parameters.  (See https://www.postgresql.org/docs/current/static/libpq-connect.html)
        listen_port: int     # The port to listen for incoming connections
        listen_addr: string  # The IP address listen for incoming connections.  Defaults to inaddr_any.
        verbose:     bool    # Be informative
        debug:       bool    # Spew out raw data
        use_color:   bool    # Pretty things up a little, probably want to disable this if debugging


# The global config object
#
# FIXME:  Rather than pass this all over the
# place, consider channels and createThread instead of spawn.
#
var conf = Config(
    dbopts: "host=localhost port=5432 dbname=netdata user=netdata application_name=netdata-tsrelay",
    listen_port: 14866,
    listen_addr: "0.0.0.0",
    verbose: true,
    debug: false,
    use_color: true
)


proc hl( msg: string, fg: ForegroundColor, bright=false ): string =
    ## Quick wrapper for color formatting a string, since the 'terminal'
    ## module only deals with stdout directly.
    if not conf.use_color: return msg

    var color: BiggestInt = ord( fg )
    if bright: inc( color, 60 )
    result = "\e[" & $color & 'm' & msg & "\e[0m"


proc fetch_data( client: Socket ): string =
    ## Netdata JSON backend doesn't send a length, so we read line by
    ## line and wait for stream timeout to determine a "sample".
    try:
        result = client.recv_line( timeout=500 ) & "\n"
        while result != "":
            result = result & client.recv_line( timeout=500 ) & "\n"
    except TimeoutError:
        discard


proc parse_data( data: string, conf: Config ): Table[ BiggestInt, JsonNode ] =
    ## Given a raw +data+ string, parse JSON and return a table of
    ## JSON samples ready for writing, keyed by timestamp. Netdata can
    ## buffer multiple samples in one batch.
    if data == "": return

    # Hash of sample timeperiods to pivoted json data
    result = init_table[ BiggestInt, JsonNode ]()

    for sample in split_lines( data ):
        if conf.debug: echo sample.hl( fgBlack, bright=true )
        if sample.len == 0: continue

        var parsed: JsonNode
        try:
            parsed = sample.parse_json
        except JsonParsingError:
            discard
            if conf.debug: echo hl( "Unable to parse sample line: " & sample.hl(fgRed, bright=true), fgRed )

        # Create or use existing Json object for modded data.
        #
        var pivot: JsonNode
        let key = parsed["timestamp"].get_num

        if result.has_key( key ):
            pivot = result[ key ]
        else:
            pivot = newJObject()
            result[ key ] = pivot

        var name = parsed[ "chart_id" ].get_str & "." & parsed[ "id" ].get_str
        pivot[ "hostname" ] = parsed[ "hostname" ]
        pivot[ name ] = parsed[ "value" ]

    return result


proc process( client: Socket, db: DBConn, conf: Config ): int =
    ## Do the work for a connected client within a thread.
    ## Returns the number of samples parsed.
    var raw_data = client.fetch_data

    # Done with the socket, netdata will automatically
    # reconnect.  Save local resources/file descriptors
    # by closing after the send is considered complete.
    #
    try:
        client.close
    except OSError:
        return

    # Pivot data and save to SQL.
    #
    var samples = parse_data( raw_data, conf )
    if samples.len != 0:
        db.exec sql( "BEGIN" )
        for timestamp, sample in samples:
            var host = sample[ "hostname" ].get_str
            sample.delete( "hostname" )
            db.exec sql( INSERT_SQL ), timestamp, host, sample
        db.exec sql( "COMMIT" )

    return samples.len


proc runthread( client: Socket, address: string, db: DBConn, conf: Config ): void {.thread.} =
    ## A thread that performs that dispatches processing and returns
    ## results.
    let t0 = cpu_time()
    var samples = client.process( db, conf )

    if conf.verbose:
        echo(
            hl( $samples, fgWhite, bright=true ),
            " sample(s) parsed from ",
            address.hl( fgYellow, bright=true ),
            " in ", hl($( round(cpu_time() - t0, 3) ), fgWhite, bright=true), " seconds."
            # " ", hl($(round((get_occupied_mem()/1024/1024),1)), fgWhite, bright=true), "MB memory used."
        )
    when defined( testing ): dumpNumberOfInstances()


proc serverloop: void =
    ## Open a database connection, bind to the listening socket,
    ## and start serving incoming netdata streams.
    let db = open( "", "", "", conf.dbopts )
    if conf.verbose: echo( "Successfully connected to the backend database.".hl( fgGreen ) )

    var
        server = newSocket()
        client = newSocket()

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

    while true:
        var address = ""
        server.acceptAddr( client, address ) # blocking call
        spawn runthread( client, address, db, conf )


proc atexit() {.noconv.} =
    ## Exit cleanly after waiting on any running threads.
    echo "Exiting..."
    sync()
    quit( 0 )


proc parse_cmdline: void =
    ## Populate the config object with the user's preferences.

    # always set debug mode if development build.
    conf.debug = defined( testing )

    for kind, key, val in getopt():
        case kind

        of cmdArgument:
            discard

        of cmdLongOption, cmdShortOption:
            case key
                of "debug", "d":
                    conf.debug = true

                of "no-color", "c":
                    conf.use_color = false

                of "help", "h":
                    echo USAGE
                    quit( 0 )

                of "quiet", "q":
                    conf.verbose = false
            
                of "version", "v":
                    echo hl( "netdata_tsrelay " & VERSION, fgWhite, bright=true )
                    quit( 0 )
               
                of "dbopts": conf.dbopts = val
                of "listen-addr", "a": conf.listen_addr = val
                of "listen-port", "p": conf.listen_port = val.parse_int

                else: discard

        of cmdEnd: assert( false ) # shouldn't reach here ever


when isMainModule:
    system.addQuitProc( resetAttributes )
    system.addQuitProc( atexit )

    parse_cmdline()

    if conf.debug: echo hl( $conf, fgYellow )
    serverloop()

