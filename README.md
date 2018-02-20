
Netdata-TSRelay
===============

What's this?
------------

This program is designed to accept JSON streams from
[Netdata](https://my-netdata.io/) clients, and write metrics to a
PostgreSQL table - specifically, [Timescale](http://timescale.com)
backed tables (though that's not technically a requirement.)


Installation
------------

You'll need a working [Nim](http://nim-lang.org) build environment and
PostgreSQL development headers to compile the binary.

Simply run `make` to build it.  Put it wherever you please.


Configuration
-------------

There are a few assumptions that should be satisfied before running
this successfully.

### Database setup

You'll need to create the destination table.

```sql
CREATE TABLE netdata (
	time timestamptz default now() not null,
	host text not null,
	metrics jsonb default '{}'::jsonb not null
);
```

Index it based on how you intend to query the data, including JSON
functional indexing, etc.  See PostgreSQL documentation for details.

Strongly encouraged:  Promote this table to a Timescale "hypertable".
See [Timescale](http://timescale.com) docs for that, but a quick example
to partition automatically at weekly boundaries would look something
like:

```sql
SELECT create_hypertable( 'netdata', 'time', chunk_time_interval => 604800000000 );
```

Timescale also has some great examples and advice for efficient [JSON
indexing](http://docs.timescale.com/v0.8/using-timescaledb/schema-management#json)
and queries.


### Netdata

You'll likely want to pare down what netdata is sending.  Here's an
example configuration for `netdata.conf` -- season this to taste (what
charts to send and frequency.)

```
[backend]
    hostname           = your-hostname
    enabled            = yes
    type               = json
    data source        = average
    destination        = machine-where-netdata-tsrelay-lives:14866
    prefix             = n
    update every       = 60
    buffer on failures = 5
    send charts matching = !cpu.cpu* !ipv6* !users* nfs.rpc net.* net_drops.* net_packets.* !system.interrupts* system.* disk.* disk_space.* disk_ops.* mem.*
```


Running the Relay
-----------------

### Options

  * [-q|--quiet]:    Quiet mode.  No output at all. Ignored if -d is supplied.
  * [-d|--debug]:    Debug mode.  Show incoming data.
  * [--dbopts]:      PostgreSQL connection information.  (See below for more details.)
  * [-h|--help]:     Display quick help text.
  * [--listen-addr]: A specific IP address to listen on.  Defaults to INADDR_ANY.
  * [--listen-port]: The port to listen for netdata JSON streams.
                     Default is 14866.
  * [-T|--dbtable]:  Change the table name to insert to.  Defaults to **netdata**.
  * [-t|--timeout]:  Maximum time in milliseconds to wait for data.  Slow
                     connections may need to increase this from the default 500 ms.
  * [-v|--version]:  Show version.


**Notes**

Nim option parsing might be slightly different than what you're used to.
Flags that require arguments must include an '=' or ':' character.

  * --timeout=1000  *valid*
  * --timeout:1000  *valid*
  * --t:1000  *valid*
  * --timeout 1000  *invalid*
  * -t 1000  *invalid*

All database connection options are passed as a key/val string to the
*dbopts* flag.  The default is:

	"host=localhost port=5432 dbname=netdata user=netdata application_name=netdata-tsrelay"

Reference
https://www.postgresql.org/docs/current/static/libpq-connect.html#LIBPQ-
PARAMKEYWORDS for all available options (including how to store
passwords in a seperate file, enable SSL mode, etc.)


### Daemonizing

Use a tool of your choice to run this at system
startup in the background.  My personal preference is
[daemontools](https://cr.yp.to/daemontools.html), but I won't judge you
if you use something else.

Here's an example using the simple
[daemon](https://www.freebsd.org/cgi/man.cgi?query=daemon&apropos=0&sektion=8&manpath=FreeBSD+11.0-RELEASE+and+Ports&arch=default&format=html) wrapper tool:

	# daemon \
		-o /var/log/netdata_tsrelay.log \
		-p /var/run/netdata_tsrelay.pid \
		-u nobody -cr \
		/usr/local/bin/netdata_tsrelay \
			--dbopts="dbname=metrics user=metrics host=db-master port=6432 application_name=netdata-tsrelay"

