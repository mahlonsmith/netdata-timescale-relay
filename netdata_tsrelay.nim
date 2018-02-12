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
    nativesockets,
    net,
    parseopt2,
    strutils,
    tables,
    threadpool


const
    VERSION = "v0.1.0"
    USAGE = """
./netdata_tsrelay --dbopts="[PostgreSQL connection string]" --listen-port=14866

The default connection string is:
  "host=localhost port=5432 dbname=netdata user=netdata application_name=netdata-tsrelay"
    """
    INSERT_SQL = """
    INSERT INTO netdata
        ( time, host, metrics )
    VALUES
        ( 'epoch'::timestamptz + ? * '1 second'::interval, ?, ? )
    """


type Config = object of RootObj
    dbopts:      string  # The postgresql connection parameters.  (See https://www.postgresql.org/docs/current/static/libpq-connect.html)
    listen_port: int     # The port to listen for incoming connections

# Global config object
#
var conf = Config(
    dbopts: "host=localhost port=5432 dbname=netdata user=netdata application_name=netdata-tsrelay",
    listen_port: 14866
)


proc fetch_data( client: Socket ): string =
    ## Netdata JSON backend doesn't send a length, so we read line by
    ## line and wait for stream timeout to determine a "sample".
    try:
        result = client.recv_line( timeout=500 ) & "\n"
        while result != "":
            result = result & client.recv_line( timeout=500 ) & "\n"
    except TimeoutError:
        discard


proc parse_data( data: string ): Table[ BiggestInt, JsonNode ] =
    ## Given a raw +data+ string, parse JSON and return a table of
    ## JSON samples ready for writing, keyed by timestamp. Netdata can
    ## buffer multiple samples in one batch.
    if data == "": return

    # Hash of sample timeperiods to pivoted json data
    result = init_table[ BiggestInt, JsonNode ]()

    for sample in split_lines( data ):
        if defined( testing ): echo sample
        if sample.len == 0: continue

        var parsed: JsonNode
        try:
            parsed = sample.parse_json
        except JsonParsingError:
            if defined( testing ): echo "Unable to parse sample line: " & sample

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

    if defined( testing ): echo $result.len & " samples"

    return result


proc process( client: Socket, db: DBConn ): void =
    ## Do the work for a connected client within a thread.
    var raw_data = client.fetch_data

    try:
        if defined( testing ):
            echo "Closed connection for " & get_peer_addr( client.get_fd, get_sock_domain(client.get_fd) )[0]
        client.close
    except OSError:
        return

    var samples = parse_data( raw_data )
    for timestamp, sample in samples:
        var host = sample[ "hostname" ].get_str
        sample.delete( "hostname" )
        db.exec sql( INSERT_SQL ), timestamp, host, sample

proc serverloop: void =
    ## Open a database connection, bind to the listening socket,
    ## and start serving incoming netdata streams.
    let db = open( "", "", "", conf.dbopts )
    echo "Successfully connected to the backend database."
    
    var server = newSocket()
    echo "Listening for incoming connections on port ", conf.listen_port, "..."
    server.set_sock_opt( OptReuseAddr, true )
    server.bind_addr( Port(conf.listen_port) )
    server.listen()

    while true:
        var
            client  = newSocket()
            address = ""

        server.acceptAddr( client, address )
        echo "New connection: " & address
        spawn client.process( db )


proc parse_cmdline: void =
    ## Populate the config object with the user's preferences.
    for kind, key, val in getopt():
        case kind

        of cmdArgument:
            discard

        of cmdLongOption, cmdShortOption:
            case key
                of "help", "h":
                    echo USAGE
                    quit( 0 )
            
                of "version", "v":
                    echo "netdata_tsrelay ", VERSION
                    quit( 0 )
               
                of "dbopts": conf.dbopts = val
                of "listen-port", "p": conf.listen_port = val.parse_int

                else: discard

        of cmdEnd: assert( false ) # shouldn't reach here ever


when isMainModule:
    parse_cmdline()
    if defined( testing ): echo conf
    serverloop()

