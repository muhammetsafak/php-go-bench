#!/usr/bin/env node
/**
 * Stands in for the authorization server.
 *
 * The services under test only ever VERIFY tokens, so the issuer does not need
 * to exist at run time: this script mints an RSA-2048 key pair and a handful of
 * RS256 access tokens once, and the candidates receive the public half through
 * a read-only mount. Every candidate verifies the same bytes.
 *
 *   valid    both scopes, 7 days to live
 *   pool     eight more tokens with both scopes, distinct jti/iat, so every
 *            load generator sends a different token and no candidate can be
 *            accidentally helped by the same bytes arriving over and over
 *   readonly events:read only — POST /events must refuse it
 *   expired  exp in the past
 *   foreign  well-formed, signed by a key the services have never seen
 *
 * Every pool token carries the same sub, because the read query filters by
 * subject and the seeded rows belong to one client.
 *
 * Output: private.pem, public.pem, public.php (the PEM as an opcache-able PHP
 * file, so php-fpm does not touch the filesystem per request), tokens.json.
 */
import { generateKeyPairSync, createSign } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = dirname(fileURLToPath(import.meta.url));
const ISSUER = 'https://auth.bench.local';
const AUDIENCE = 'events-api';

const b64url = (buf) => Buffer.from(buf).toString('base64url');

const pair = () =>
  generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });

const sign = (privateKey, claims) => {
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid: 'bench-1' }));
  const payload = b64url(JSON.stringify(claims));
  const signer = createSign('RSA-SHA256');
  signer.update(`${header}.${payload}`);
  return `${header}.${payload}.${b64url(signer.sign(privateKey))}`;
};

const now = Math.floor(Date.now() / 1000);
const base = {
  iss: ISSUER,
  aud: AUDIENCE,
  sub: 'client-bench',
  client_id: 'client-bench',
  iat: now,
  nbf: now - 60,
  exp: now + 7 * 24 * 3600,
  scope: 'events:read events:write',
};

const { publicKey, privateKey } = pair();
const foreign = pair();

const POOL_SIZE = 8;

const tokens = {
  valid: sign(privateKey, base),
  pool: Array.from({ length: POOL_SIZE }, (_, i) =>
    sign(privateKey, { ...base, jti: `bench-${i + 1}`, iat: now - i })),
  readonly: sign(privateKey, { ...base, scope: 'events:read' }),
  expired: sign(privateKey, { ...base, iat: now - 7200, nbf: now - 7200, exp: now - 3600 }),
  foreign: sign(foreign.privateKey, base),
};

writeFileSync(join(dir, 'private.pem'), privateKey, { mode: 0o600 });
writeFileSync(join(dir, 'public.pem'), publicKey);
writeFileSync(join(dir, 'public.php'), `<?php return ${JSON.stringify(publicKey)};\n`);
writeFileSync(join(dir, 'tokens.json'), JSON.stringify({ issuer: ISSUER, audience: AUDIENCE, expiresAt: base.exp, ...tokens }, null, 2) + '\n');
console.log(`keys and ${POOL_SIZE + 3} tokens written to ${dir} (valid until ${new Date(base.exp * 1000).toISOString()})`);
