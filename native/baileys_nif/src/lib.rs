//! Native NIF implementations for transport `Noise` and `XEdDSA` helpers.

#![deny(missing_docs)]

mod error;
mod noise;
mod xeddsa;

rustler::init!("Elixir.BaileysEx.Native");
