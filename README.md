
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
like this, if you're running v0.9.0 or better:

```sql
SELECT create_hypertable( 'netdata', 'time', migrate_data => true, chunk_time_interval => '1 week'::interval );
```

Timescale also has some great examples and advice for efficient [JSON
indexing](https://docs.timescale.com/timescaledb/latest/how-to-guides/schema-management/json/#json)
and queries.


### Netdata

You'll likely want to pare down what netdata is sending.  Here's an
example configuration for `exporting.conf` -- season this to taste (what
charts to send and frequency.)

Note: This example uses the "exporting" module introduced in
Netdata v1.23.  If your netdata is older than that, you'll be using
the deprecated "backend" instead in the main `netdata.conf` file.

```
[exporting:global]
	enabled  = yes
	hostname = your-hostname

[json:timescale]
	enabled              = yes
	data source          = average
	destination          = localhost:14866
	prefix               = netdata
	update every         = 10
	buffer on failures   = 10
	send charts matching = !cpu.cpu* !ipv6* !users.* nfs.rpc net.* net_drops.* net_packets.* !system.interrupts* system.* disk.* disk_space.* disk_ops.* mem.*
```


Running the Relay
-----------------

### Options

  * [-q|--quiet]:    Quiet mode.  No output at all. Ignored if -d is supplied.
  * [-d|--debug]:    Debug mode.  Show incoming data.
  * [-D|--dropconn]: Drop the TCP connection to netdata between samples.
                     This may be more efficient depending on your environment and
                     number of clients.  Defaults to false.
  * [-o|--dbopts]:   PostgreSQL connection information.  (See below for more details.)
  * [-h|--help]:     Display quick help text.
  * [-a|--listen-addr]: A specific IP address to listen on.  Defaults to **INADDR_ANY**.
  * [-p|--listen-port]: The port to listen for netdata JSON streams.
                     Default is **14866**.
  * [-P|--persistent]: Don't disconnect from the database between samples. This may be
                     more efficient with a small number of clients, when not using a
                     pooler, or with a very high sample size/rate.  Defaults to false.
  * [-T|--dbtable]:  Change the table name to insert to.  Defaults to **netdata**.
  * [-t|--timeout]:  Maximum time in milliseconds to wait for data.  Slow
                     connections may need to increase this from the default **500** ms.
  * [-v|--version]:  Show version.



**Notes**

Nim option parsing might be slightly different than what you're used to.
Flags that require arguments must include an '=' or ':' character.

  * --timeout=1000  *valid*
  * --timeout:1000  *valid*
  * -t:1000  *valid*
  * --timeout 1000  *invalid*
  * -t 1000  *invalid*

All database connection options are passed as a key/val string to the
*dbopts* flag.  The default is:

	"host=localhost dbname=netdata application_name=netdata-tsrelay"

... which uses the default PostgreSQL port, and connects as the running
user.

Reference the [PostgreSQL Documentation](https://www.postgresql.org/docs/current/static/libpq-connect.html#LIBPQ-PARAMKEYWORDS)
for all available options (including how to store passwords in a
separate file, enable SSL mode, etc.)


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

### Scaling

Though performant by default, if you're going to be storing a LOT of
data (or have a lot of netdata clients), here are some suggestions for
getting the most bang for your buck:

  * Use the [pgbouncer](https://pgbouncer.github.io/) connection
    pooler.
  * DNS round robin the hostname where **netdata_tsrelay** lives across
    *N* hosts -- you can horizontally scale without any gotchas.
  * Edit your **netdata.conf** file to only send the metrics you are
    interested in.
  * Decrease the frequency at which netdata sends its data. (When in
    "average" mode, it averages over that time automatically.)
  * Use [Timescale](http://timescale.com) hypertables.
  * Add database indexes specific to how you intend to consume the data.
  * Use the PostgreSQL
    [JSON Operators](https://www.postgresql.org/docs/current/static/functions-json.html#FUNCTIONS-JSONB-OP-TABLE),
	which take advantage of GIN indexing.
  * Put convenience SQL VIEWs around the data you're fetching later, for
    easier graph building with [Grafana](https://grafana.com/) (or whatever.)

# Deploying as Service
  * Compile netdata_relay
  * Edit `netdata-relay.service` file to match your parameters
  * Move `netdata-relay.service` to `/etc/systemd/system`
  * Run `systemctl daemon-reload`
  * Run `systemctl enable --now netdata-relay`
  * If you want debug you can check journal with `journalctl -u netdata-relay`