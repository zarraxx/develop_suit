#!/usr/bin/env node

'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const crypto = require('crypto');
const dns = require('dns/promises');
const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');
const zlib = require('zlib');

const localhostKey = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCLuhuOKrRziLVf
MQPWLD8qTM6oIvvPv6CPQoKEY0UI09NV6wBCtkB2P0WnHw28+F/aficd4X7o5pFK
aPvjxfrNLa9nE32tj9Ql8QEyET9GUiSpf1pBV9RxiHZOWTtbi+1k5nmE0bLYKcS9
CGBEOv9YCEst4e5IN4MF6x2xtf+S7hc/2lbQXMM5g2vbu26f7Lj9snSCoBFf+Uaa
gaaGrIX70fe3MWDeG2CmLMwP0UTRvt4Du6SmiaaM53V3jU9TsPkLsODyE0XqrKp2
IW/tMMYZqDM6U7lJ1lv8h5oBFmQWmv5WMU/5VTHOgy4h2q7KiXkHnOvruAKe9RAK
BhiGW9U/AgMBAAECggEAFFIFjeBiC+dW0Tg0oaIfsYwoBcXIr0bkF9GJX618LbN4
qacai5kruMas34ghnFjWv9TW5X6U0VQuzw6Di3WQauR4/NmVznb7WGU7Uke11wk9
MbVGr/gQ+k3pPq21dzPbW3A1Pf6tLsisRv1/2oxl9CyImmygFbqVAHhYAi9AsuJc
SRRMFe3I2QqZAgepD7QK2Lcap1zbNMZl3NJ/1E1UaHyMSAy4taH9sdIIjYtDdLez
B/Cs6b637+cGsPSvI6gUdV9Ja3NEbdGKWynqJ5OAqDt+nAE0hbi8vcIuNHYKd2mF
i4rFFGfh2O3CtAaGJniF5BVSh7jLuGFVfVSKF/C1IQKBgQDFjKa+DC8uGFJECNiD
azzhIFpeodqtk67HicCM7W79RtvsBsY4Gw+nrBNj8F0uqrxuRUKh+iO1J7mEfscp
rW+1gyK8GBTgNaBrHNJfah2ToUAHLBOOOtUPtR/N48Do4K/yi54sbdN4TT0+5I7x
+nR9jWg4Eyh83il237sVPFSX0QKBgQC1EbSLu7iBy5rfxObB2+LIBh5TwBGu2p4s
ksXBjsmkYJiNntNNA1RDCn2w3s6akkGXKCxv9E/D7pFjC6V0y77GtENKn5UOhKyf
RdrqHcTy0eZBgM/2AzvJN49xeP/hnVQRl18mCcZ6jQV7KE/zJnHagRODqI22A+qS
MNGz9aPwDwKBgD6DkuSDMI7yrV3QOsvjrKFFPrPBnlTdbirAwckW/c9yk/et8R4i
GiMiRgSTNLmm1/hBPKPLZ29VQdTW1amvs7EJ7Xz+VeTZs4kR1tTQ3Mkx9vQOE6Yn
ofLVi1n5H7vSFnu3iPdgTdI9BwuXAlE6w5BTpk5QabiSCScQB8DhlZdxAoGAKyoA
Vzs13cMytVtUAyyu4C4NNrvXu04kXM3UVLL8QLJCS6hsCLTddmne0rYanGB3QFh0
V2/vP+70O59AHxqe7PF2BSkLuH1KRWG6sQrNs3D0KfNSH/xfWTVkfZFxtk/yBYuH
RCMabIaHovdWL8mfZI5Wn5EjzxsZ5SW8J+FL5mMCgYEAwpJ3/oTXCq0flrLlvEuZ
VI/0ddjq3iIuzgDpQCyrf7CvPfg3rjk8eAwKZGDiTHXNNO29KgoFDAt3mMhGUwLy
lJOKuCoCxptTT9aHwmpDcHsP9zmiA8jvNyxAYlhVeksDOGQUdUjajKGgvJKZUHdK
mSzr6LHpsIgafYbZsnR35Ew=
-----END PRIVATE KEY-----`;

const localhostCert = `-----BEGIN CERTIFICATE-----
MIIDJTCCAg2gAwIBAgIUaN5aP0+YgJT87q+zBNZ8OdNfPuwwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDYwMzIzNTcwMFoXDTM2MDUz
MTIzNTcwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAi7objiq0c4i1XzED1iw/KkzOqCL7z7+gj0KChGNFCNPT
VesAQrZAdj9Fpx8NvPhf2n4nHeF+6OaRSmj748X6zS2vZxN9rY/UJfEBMhE/RlIk
qX9aQVfUcYh2Tlk7W4vtZOZ5hNGy2CnEvQhgRDr/WAhLLeHuSDeDBesdsbX/ku4X
P9pW0FzDOYNr27tun+y4/bJ0gqARX/lGmoGmhqyF+9H3tzFg3htgpizMD9FE0b7e
A7ukpommjOd1d41PU7D5C7Dg8hNF6qyqdiFv7TDGGagzOlO5SdZb/IeaARZkFpr+
VjFP+VUxzoMuIdquyol5B5zr67gCnvUQCgYYhlvVPwIDAQABo28wbTAdBgNVHQ4E
FgQUF5r/VLi0YgPWzIWNHuibz9pn3OswHwYDVR0jBBgwFoAUF5r/VLi0YgPWzIWN
Huibz9pn3OswDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SH
BH8AAAEwDQYJKoZIhvcNAQELBQADggEBACfERudNrMx2YCby1KEfj4MP2xf4DJED
jdrdEtQixRnh3Zjdp1fUnvbDDhdyO1BUnT1zMTFzAgLPKJ74xufIciQ+plAaXYG1
k+ReV30xfmNa2bMrNd6+kcyeHPeuiRMrUXOUGoD89Tv2xtmZ1/U1EY264HuWA8tr
h/DJmrprVD9mjtRsg5biU5945NM9tofyAEQJwskW9AD1b5zxWRqGmlzswffFjRgG
9YfDJ74aX6YrRRompaLNz3X3VOKPMPBpnOoAoplWl5I6G7dQMhgnZUtE/Jf7XJd7
6Hh3DGsKKADSUUz+KlJc2ofsCNMlWfXN/bm3NE+ZMhODwrEBgWJUb5k=
-----END CERTIFICATE-----`;

async function testHttps() {
  const server = https.createServer(
    { key: localhostKey, cert: localhostCert },
    (request, response) => {
      assert.strictEqual(request.method, 'POST');
      let body = '';
      request.setEncoding('utf8');
      request.on('data', (chunk) => {
        body += chunk;
      });
      request.on('end', () => {
        response.setHeader('content-type', 'application/json');
        response.end(JSON.stringify({
          ok: true,
          body,
          protocol: request.socket.getProtocol(),
        }));
      });
    },
  );

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  try {
    const result = await new Promise((resolve, reject) => {
      const request = https.request({
        ca: localhostCert,
        hostname: 'localhost',
        method: 'POST',
        path: '/smoke',
        port,
        servername: 'localhost',
      }, (response) => {
        assert.strictEqual(response.statusCode, 200);
        let body = '';
        response.setEncoding('utf8');
        response.on('data', (chunk) => {
          body += chunk;
        });
        response.on('end', () => resolve(JSON.parse(body)));
      });
      request.on('error', reject);
      request.end('hello https');
    });

    assert.deepStrictEqual(result.ok, true);
    assert.strictEqual(result.body, 'hello https');
    assert.match(result.protocol, /^TLSv1\.[23]$/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function main() {
  assert.match(process.version, /^v24\./);

  const digest = crypto.createHash('sha256').update('develop-suit').digest('hex');
  assert.strictEqual(digest, 'fdcfd54d4585d00046fcd7989de212a951545ab7b182d27d35b432a1b768ecca');
  assert.strictEqual(crypto.randomBytes(16).length, 16);

  const compressed = zlib.gzipSync(Buffer.from('nodejs smoke'));
  assert.strictEqual(zlib.gunzipSync(compressed).toString(), 'nodejs smoke');

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodejs-smoke-'));
  const filePath = path.join(tempDir, 'sample.txt');
  fs.writeFileSync(filePath, 'filesystem ok\n');
  assert.strictEqual(fs.readFileSync(filePath, 'utf8'), 'filesystem ok\n');
  fs.rmSync(tempDir, { force: true, recursive: true });

  const lookup = await dns.lookup('localhost');
  assert.ok(['4', '6'].includes(String(lookup.family)));

  const child = childProcess.execFileSync(process.execPath, ['-e', 'process.stdout.write("child ok")']);
  assert.strictEqual(child.toString(), 'child ok');

  await testHttps();

  console.log(`nodejs smoke ok ${process.version}`);
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exitCode = 1;
});
