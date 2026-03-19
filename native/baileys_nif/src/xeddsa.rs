use crate::error::NifError;
use curve25519_dalek::{
    constants::ED25519_BASEPOINT_POINT, edwards::CompressedEdwardsY, montgomery::MontgomeryPoint,
    scalar::Scalar,
};
use rustler::{Binary, Env, NewBinary, NifResult};
use sha2::{Digest, Sha512};

#[rustler::nif(name = "xeddsa_sign")]
fn sign<'a>(env: Env<'a>, private_key: Binary<'a>, message: Binary<'a>) -> NifResult<Binary<'a>> {
    let private_key: [u8; 32] = private_key
        .as_slice()
        .try_into()
        .map_err(|_| NifError::PrivateKeyMustBe32Bytes)?;

    let mut clamped = private_key;
    clamped[0] &= 248;
    clamped[31] &= 127;
    clamped[31] |= 64;

    let a = Scalar::from_bytes_mod_order(clamped);
    let big_a = a * ED25519_BASEPOINT_POINT;
    let sign_bit = big_a.compress().to_bytes()[31] & 0x80;
    let public_point_bytes = big_a.compress().to_bytes();

    let nonce_hash = Sha512::new()
        .chain_update(clamped)
        .chain_update(message.as_slice())
        .finalize();
    let r = Scalar::from_bytes_mod_order_wide(&nonce_hash.into());

    let big_r = r * ED25519_BASEPOINT_POINT;
    let nonce_point_bytes = big_r.compress().to_bytes();

    let h_hash = Sha512::new()
        .chain_update(nonce_point_bytes)
        .chain_update(public_point_bytes)
        .chain_update(message.as_slice())
        .finalize();
    let h = Scalar::from_bytes_mod_order_wide(&h_hash.into());

    let s = r + h * a;

    let mut out = NewBinary::new(env, 64);
    out.as_mut_slice()[..32].copy_from_slice(&nonce_point_bytes);
    out.as_mut_slice()[32..].copy_from_slice(s.as_bytes());
    out.as_mut_slice()[63] |= sign_bit;
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

    let sign_bit = (signature[63] >> 7) & 1;
    let montgomery = MontgomeryPoint(public_key);
    let Some(edwards) = montgomery.to_edwards(sign_bit) else {
        return false;
    };

    let nonce_bytes: [u8; 32] = match signature[..32].try_into() {
        Ok(bytes) => bytes,
        Err(_) => return false,
    };

    let mut s_bytes: [u8; 32] = match signature[32..].try_into() {
        Ok(bytes) => bytes,
        Err(_) => return false,
    };
    s_bytes[31] &= 0x7f;

    let Some(big_r) = CompressedEdwardsY(nonce_bytes).decompress() else {
        return false;
    };

    let Some(s) = Option::<Scalar>::from(Scalar::from_canonical_bytes(s_bytes)) else {
        return false;
    };

    let public_point_bytes = edwards.compress().to_bytes();

    let h_hash = Sha512::new()
        .chain_update(nonce_bytes)
        .chain_update(public_point_bytes)
        .chain_update(message.as_slice())
        .finalize();
    let h = Scalar::from_bytes_mod_order_wide(&h_hash.into());

    s * ED25519_BASEPOINT_POINT - h * edwards == big_r
}
