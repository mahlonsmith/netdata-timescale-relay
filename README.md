
Netdata-TSRelay
===============

What's this?
------------

This program is designed to accept JSON streams from
[Netdata](http://netdata.io) clients, and write metrics to a PostgreSQL table -
specifically, [Timescale](http://timescale.com) backed tables (though
that's not technically a requirement.)


Installation
------------

You'll need a working [Nim](http://nim-lang.org) build environment to
create the binary.

Simply run `make release` to produce the binary.  Put it wherever you
please.


Configuration
-------------

There are a few assumptions that should be satisfied before running
this.

### Database setup

You'll need to create the destination table.

```sql
CREATE TABLE netdata (
	time timestamptz default now() not null,
	host text not null,
	metrics jsonb default '{}'::jsonb not null
);
```

Index it however you please based on how you intend to query the data,
including JSON functional indexing, etc.  See PostgreSQL documentation
for details.

Strongly encouraged:  Promote this table to a Timescale "hypertable".
See Timescale docs for that, but a quick example to partition
automatically at weekly boundaries would look something like:

```sql
SELECT create_hypertable( 'netdata', 'time', chunk_time_interval => 604800000000 );
```



### Netdata

You'll likely want to pare down what netdata is sending.  Here's an
example configuration for `netdata.conf`:

```
[backend]
    hostname           = your-hostname
    enabled            = yes
    type               = json
    data source        = average
    destination        = machine-where-netdata-tsrelay-lives:14866
    prefix             = n
    update every       = 10
    buffer on failures = 6
    send charts matching = !cpu.cpu* !ipv6* !users* nfs.rpc net.* net_drops.* net_packets.* !system.interrupts* system.* disk.* disk_space.* disk_ops.* mem.*
```

