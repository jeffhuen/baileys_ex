use curve25519_dalek::{
    constants::ED25519_BASEPOINT_POINT,
    edwards::CompressedEdwardsY,
    montgomery::MontgomeryPoint,
    scalar::Scalar,
};
use rustler::{Binary, Env, NewBinary, NifResult};
use sha2::{Digest, Sha512};

#[rustler::nif(name = "xeddsa_sign")]
fn sign<'a>(env: Env<'a>, private_key: Binary<'a>, message: Binary<'a>) -> NifResult<Binary<'a>> {
    let private_key: [u8; 32] = private_key
        .as_slice()
        .try_into()
        .map_err(|_| rustler::Error::RaiseTerm(Box::new("private key must be 32 bytes")))?;

    let mut random_bytes = [0u8; 64];
    getrandom::getrandom(&mut random_bytes)
        .map_err(|e| rustler::Error::RaiseTerm(Box::new(format!("rng failed: {e}"))))?;

    let a = Scalar::from_bytes_mod_order(private_key);
    let big_a = &a * &ED25519_BASEPOINT_POINT;

    let (a_adj, big_a_adj) = if big_a.compress().to_bytes()[31] & 0x80 != 0 {
        (-a, -big_a)
    } else {
        (a, big_a)
    };

    let big_a_bytes = big_a_adj.compress().to_bytes();

    let nonce_hash = Sha512::new()
        .chain_update([0xFE_u8])
        .chain_update(a_adj.as_bytes())
        .chain_update(message.as_slice())
        .chain_update(random_bytes)
        .finalize();
    let r = Scalar::from_bytes_mod_order_wide(&nonce_hash.into());

    let big_r = &r * &ED25519_BASEPOINT_POINT;
    let big_r_bytes = big_r.compress().to_bytes();

    let h_hash = Sha512::new()
        .chain_update(big_r_bytes)
        .chain_update(big_a_bytes)
        .chain_update(message.as_slice())
        .finalize();
    let h = Scalar::from_bytes_mod_order_wide(&h_hash.into());

    let s = r + h * a_adj;

    let mut out = NewBinary::new(env, 64);
    out.as_mut_slice()[..32].copy_from_slice(&big_r_bytes);
    out.as_mut_slice()[32..].copy_from_slice(s.as_bytes());
    Ok(out.into())
}

#[rustler::nif(name = "xeddsa_verify")]
fn verify(public_key: Binary, message: Binary, signature: Binary) -> bool {
    let public_key: [u8; 32] = match public_key.as_slice().try_into() {
        Ok(key) => key,
        Err(_) => return false,
    };

    let signature: [u8; 64] = match signature.as_slice().try_into() {
        Ok(sig) => sig,
        Err(_) => return false,
    };

    let montgomery = MontgomeryPoint(public_key);
    let edwards = match montgomery.to_edwards(0) {
        Some(point) => point,
        None => return false,
    };

    let big_r_bytes: [u8; 32] = signature[..32].try_into().unwrap();
    let s_bytes: [u8; 32] = signature[32..].try_into().unwrap();

    let big_r = match CompressedEdwardsY(big_r_bytes).decompress() {
        Some(point) => point,
        None => return false,
    };

    let s = match Option::<Scalar>::from(Scalar::from_canonical_bytes(s_bytes)) {
        Some(scalar) => scalar,
        None => return false,
    };

    let big_a_bytes = edwards.compress().to_bytes();

    let h_hash = Sha512::new()
        .chain_update(big_r_bytes)
        .chain_update(big_a_bytes)
        .chain_update(message.as_slice())
        .finalize();
    let h = Scalar::from_bytes_mod_order_wide(&h_hash.into());

    &s * &ED25519_BASEPOINT_POINT - &h * &edwards == big_r
}
