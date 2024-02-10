# Simple SDRAM Controller

     Till Straumann <till.straumann@alumni.tu-berlin.de>, 2024.

This controller interfaces to a standard SDRAM using
a pipelined architecture in the output direction.

It uses a burst size of 1 and thus expects a valid address
during each cycle. Rows are kept open as long as possible,
i.e., continuous access to random columns within one row
is most efficient (and can be sustained at the full band-
width).

If a bank switch is necessary then the new bank is opened
and the previously active one is closed.

The controller is designed to efficiently implement e.g.,
store-and-forward FIFOs.

Crucial parameters of the SDRAM device are communicated
to the controller by means of generics.

## Implementation Notes

Events which affect throughput (in increasing order of
impact):

  1. continuous read- or write- access supported within a
     single row at full speed.

  2. Switching from write to read (within the same row)
     incurs a 1-cycle penalty (defined by write latency
     of the RAM).

  3. Switching from read to write (within the same row)
     incurs a small penalty (CAS latency of RAM) to
     drain the readback pipeline and turn the DQ bus.

  4. Accessing a row in a different bank requires
     (assuming the current bank has been active for
     at least the minimum RAS time; while it would
     be possible to delay closing the current bank
     in this case and already open the new one this
     is not supported). Preload of the old bank is
     happening while the new bank is already active.

     A delay of T_RCD (plus 1 cycle decision time) is
     required before read or write access is possible.

  5. Accessing a new row in the currently active bank
     requires the current row to be closed (T_RP) and
     the new one to be opened (T_RCD) before read or
     write access is possible.


When a auto-refresh interval expires then the currently
active bank is precharged and a refresh cycle is executed.
This takes precedence over any attempted access.

## Address Mapping

The user-facing address bus is mapped to

     ROW - BANK - COLUMN

i.e., the row-address is mapped to the most- and
the column address to the least significant bits,
separated by the bank address.

This mapping ensures most efficient operation when
accessing sequential addresses (remaining for
most of the time within a single bank and never
switching rows within the same bank).

## User Interface

The user interface consists of address-, read-data-
and write-data busses, a write-strobe bus and handshake
signals:

  `req` is asserted to request access

  `rdnwr` defines the direction of the access (`1` for
  read, `0` for write.

  `ack` is asserted by the controller when the access
   is accepted.

   `val` is asserted by the controller when read data is
   valid (`CAS_LAT_G` cycles after the corresponding
   `ack`).

Note that once `req` is asserted the user must hold all signals 
steady until `ack` is seen (which may be on the same cycle
as `req` or at a later time).

The `wstrb` bits can be de-asserted to disable writing
to dedicated byte-lanes.

## Read-path Registering

Note that the read-data is *not* registered in the
controller since this is easy to add externally and
not required by the controller itself.

## Additional Pipeline Stage

When setting the generic `INP_REG_G => 1` then a pipeline
stage is added to the bus interface which decouples several
address comparisons from the bus-interface ports. This
may be beneficial for timing closure but adds one clock cycle
of latency. The max. throughput is not affected. The generic
may also be set to `2` in which case the `ack` signal is
also registered eliminating more combinatorial paths.
In this case all input signals must be internally double-
buffered (doubling the number of registers used compared
to `INP_REG_G => 1`).

## License

The SDRAM controller is released under the [European-Union Public
License](https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12).

The EUPL permits including/merging/distributing the licensed code with
products released under some other licenses, e.g., the GPL variants.

I'm also open to use a different license.
