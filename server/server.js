/**
 * RJ Music Jam Session – WebSocket Server
 *
 * Rooms are identified by the session code in the URL path.
 * e.g. ws://yourhost:8080/ABC123
 *
 * Messages are broadcast to all OTHER peers in the same room.
 * The server does NOT interpret or modify messages — it only relays them.
 *
 * Routes:
 *   /health  – JSON stats
 *   /admin   – HTML admin dashboard (auto-refreshes every 5 s)
 *
 * Deploy: any Node.js host (Railway, Render, Fly.io, VPS, etc.)
 * Run:    node server.js
 * Port:   8080 (override with PORT env variable)
 */

const { WebSocketServer } = require('ws');
const http = require('http');

const PORT = process.env.PORT || 8080;
const SERVER_START = Date.now();

// rooms: Map<roomCode, { peers: Set<WebSocket>, createdAt: number, peakPeers: number, totalJoined: number }>
const rooms = new Map();

// sessionHistory: last 50 completed sessions
const SESSION_HISTORY_LIMIT = 50;
const sessionHistory = [];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatUptime(ms) {
    const s = Math.floor(ms / 1000);
    const m = Math.floor(s / 60);
    const h = Math.floor(m / 60);
    const d = Math.floor(h / 24);
    if (d > 0) return `${d}d ${h % 24}h ${m % 60}m`;
    if (h > 0) return `${h}h ${m % 60}m ${s % 60}s`;
    if (m > 0) return `${m}m ${s % 60}s`;
    return `${s}s`;
}

function formatAge(createdAt) {
    return formatUptime(Date.now() - createdAt);
}

function totalPeers() {
    let n = 0;
    for (const { peers } of rooms.values()) n += peers.size;
    return n;
}

// ---------------------------------------------------------------------------
// Admin Dashboard HTML
// ---------------------------------------------------------------------------

function buildAdminHtml() {
    const uptime = formatUptime(Date.now() - SERVER_START);
    const roomCount = rooms.size;
    const peerCount = totalPeers();

    let roomRows = '';
    if (roomCount === 0) {
        roomRows = '<tr><td colspan="5" style="text-align:center;color:#888">No active jams</td></tr>';
    } else {
        for (const [code, { peers, createdAt, peakPeers, totalJoined }] of rooms.entries()) {
            roomRows += `
            <tr>
                <td><code style="font-size:1.1em;letter-spacing:4px">${code}</code></td>
                <td>${peers.size}</td>
                <td>${peakPeers}</td>
                <td>${formatAge(createdAt)}</td>
                <td>
                    <span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${peers.size > 0 ? '#4caf50' : '#f44336'}"></span>
                    ${peers.size > 0 ? 'Active' : 'Empty'}
                </td>
            </tr>`;
        }
    }

    let historyRows = '';
    if (sessionHistory.length === 0) {
        historyRows = '<tr><td colspan="5" style="text-align:center;color:#888">No sessions recorded yet</td></tr>';
    } else {
        for (const s of [...sessionHistory].reverse()) {
            const endedAt = new Date(s.endedAt).toLocaleTimeString();
            historyRows += `
            <tr>
                <td><code style="letter-spacing:3px">${s.code}</code></td>
                <td>${s.peakPeers}</td>
                <td>${s.totalJoined}</td>
                <td>${formatUptime(s.durationMs)}</td>
                <td style="color:#888;font-size:0.85em">${endedAt}</td>
            </tr>`;
        }
    }

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RJ Music – Jam Server Admin</title>
    <meta http-equiv="refresh" content="5">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #0f0f0f;
            color: #e0e0e0;
            min-height: 100vh;
            padding: 32px 24px;
        }
        h1 { font-size: 1.6rem; font-weight: 700; color: #fff; }
        .subtitle { color: #888; font-size: 0.85rem; margin-top: 4px; }
        .header { display: flex; align-items: center; gap: 12px; margin-bottom: 32px; }
        .logo { font-size: 2rem; }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 16px;
            margin-bottom: 32px;
        }
        .stat {
            background: #1e1e1e;
            border: 1px solid #2e2e2e;
            border-radius: 12px;
            padding: 20px;
        }
        .stat-label { font-size: 0.75rem; color: #888; text-transform: uppercase; letter-spacing: 1px; }
        .stat-value { font-size: 2rem; font-weight: 700; color: #fff; margin-top: 6px; }
        .stat-value.green { color: #4caf50; }
        .stat-value.blue { color: #2196f3; }
        h2 { font-size: 1rem; font-weight: 600; color: #ccc; margin-bottom: 12px; margin-top: 32px; }
        table {
            width: 100%;
            border-collapse: collapse;
            background: #1e1e1e;
            border-radius: 12px;
            overflow: hidden;
        }
        th {
            background: #262626;
            padding: 12px 16px;
            text-align: left;
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: #888;
        }
        td { padding: 14px 16px; border-top: 1px solid #2a2a2a; font-size: 0.9rem; }
        tr:hover td { background: #252525; }
        .refresh-note { margin-top: 16px; font-size: 0.8rem; color: #555; text-align: right; }
        code { background: #2a2a2a; padding: 2px 8px; border-radius: 6px; }
        .section-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 2px; color: #555; margin-bottom: 6px; }
    </style>
</head>
<body>
    <div class="header">
        <div class="logo">🎵</div>
        <div>
            <h1>RJ Music — Jam Server</h1>
            <div class="subtitle">Admin Dashboard&nbsp;&nbsp;·&nbsp;&nbsp;Auto-refreshes every 5 seconds</div>
        </div>
    </div>

    <div class="stats">
        <div class="stat">
            <div class="stat-label">Active Jams</div>
            <div class="stat-value green">${roomCount}</div>
        </div>
        <div class="stat">
            <div class="stat-label">Connected Peers</div>
            <div class="stat-value blue">${peerCount}</div>
        </div>
        <div class="stat">
            <div class="stat-label">Server Uptime</div>
            <div class="stat-value">${uptime}</div>
        </div>
    </div>

    <h2>Active Jam Rooms</h2>
    <table>
        <thead>
            <tr>
                <th>Room Code</th>
                <th>Live Peers</th>
                <th>Peak Peers</th>
                <th>Age</th>
                <th>Status</th>
            </tr>
        </thead>
        <tbody>
            ${roomRows}
        </tbody>
    </table>

    <h2>Session History <span style="font-size:0.75rem;color:#555;font-weight:400">(last ${SESSION_HISTORY_LIMIT})</span></h2>
    <table>
        <thead>
            <tr>
                <th>Room Code</th>
                <th>Peak Peers</th>
                <th>Total Joined</th>
                <th>Duration</th>
                <th>Ended At</th>
            </tr>
        </thead>
        <tbody>
            ${historyRows}
        </tbody>
    </table>

    <div class="refresh-note">Last updated: ${new Date().toUTCString()}</div>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

const httpServer = http.createServer((req, res) => {
    const url = req.url?.split('?')[0] || '/';

    if (url === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status: 'ok',
            rooms: rooms.size,
            peers: totalPeers(),
            uptimeMs: Date.now() - SERVER_START,
        }));
        return;
    }

    // /.well-known/assetlinks.json — required for Android App Links verification
    if (url === '/.well-known/assetlinks.json') {
        const assetLinks = JSON.stringify([{
            relation: ['delegate_permission/common.handle_all_urls'],
            target: {
                namespace: 'android_app',
                package_name: 'com.jhelum.rj_music',
                // Replace with your actual release APK SHA-256 fingerprint.
                // Get it with: keytool -list -v -keystore your-release-key.jks
                // Or from Google Play Console → App Integrity → App signing key certificate.
                sha256_cert_fingerprints: [
                    process.env.APP_SHA256 || 'REPLACE_WITH_YOUR_SHA256_FINGERPRINT'
                ]
            }
        }], null, 2);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(assetLinks);
        return;
    }

    // /join/<CODE> — shareable web link that redirects into the app
    const joinMatch = url.match(/^\/join\/([A-Za-z0-9]+)$/);
    if (joinMatch) {
        const code = joinMatch[1].toUpperCase();
        const deepLink = `rjmusic://open/jam/${code}`;
        const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Join RJ Music Jam</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #0f0f0f; color: #e0e0e0;
            min-height: 100vh;
            display: flex; align-items: center; justify-content: center;
            padding: 24px;
        }
        .card {
            background: #1e1e1e; border: 1px solid #2e2e2e;
            border-radius: 20px; padding: 40px 32px;
            max-width: 400px; width: 100%; text-align: center;
        }
        .emoji { font-size: 3rem; margin-bottom: 16px; }
        h1 { font-size: 1.4rem; font-weight: 700; color: #fff; margin-bottom: 8px; }
        .code {
            display: inline-block; font-size: 1.8rem; font-weight: 800;
            letter-spacing: 10px; color: #fff; background: #2a2a2a;
            padding: 12px 24px; border-radius: 12px; margin: 16px 0;
        }
        p { color: #888; font-size: 0.9rem; margin-bottom: 24px; }
        .btn {
            display: block; background: #e53935; color: #fff;
            text-decoration: none; padding: 16px; border-radius: 12px;
            font-weight: 700; font-size: 1rem; margin-bottom: 12px;
        }
        .small { font-size: 0.78rem; color: #555; margin-top: 16px; }
    </style>
</head>
<body>
    <div class="card">
        <div class="emoji">🎧</div>
        <h1>You're invited to a Jam!</h1>
        <div class="code">${code}</div>
        <p>Open RJ Music and join the session to listen together.</p>
        <a class="btn" href="${deepLink}">Open in RJ Music</a>
        <p class="small">Make sure RJ Music is installed on your device.</p>
    </div>
    <script>
        setTimeout(function () { window.location.href = '${deepLink}'; }, 400);
    </script>
</body>
</html>`;
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(html);
        return;
    }

    if (url === '/admin') {

        // Basic Auth
        const ADMIN_USER = 'admin';
        const ADMIN_PASS = 'admin@123';
        const authHeader = req.headers['authorization'] || '';
        const b64 = authHeader.startsWith('Basic ') ? authHeader.slice(6) : '';
        const [user, pass] = Buffer.from(b64, 'base64').toString().split(':');
        if (user !== ADMIN_USER || pass !== ADMIN_PASS) {
            res.writeHead(401, {
                'WWW-Authenticate': 'Basic realm="RJ Music Admin"',
                'Content-Type': 'text/plain',
            });
            res.end('Unauthorized');
            return;
        }
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(buildAdminHtml());
        return;
    }

    res.writeHead(200);
    res.end('RJ Music Jam Server running');
});

// ---------------------------------------------------------------------------
// WebSocket server
// ---------------------------------------------------------------------------

const wss = new WebSocketServer({ server: httpServer });

// Ping every 25 s to keep connections alive through NAT/proxies
// and detect zombie peers.
const PING_INTERVAL_MS = 25_000;

const pingInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
        if (ws.isAlive === false) {
            // Didn't respond to last ping — terminate
            ws.terminate();
            return;
        }
        ws.isAlive = false;
        ws.ping();
    });
}, PING_INTERVAL_MS);

wss.on('close', () => clearInterval(pingInterval));

wss.on('connection', (ws, req) => {
    // Ignore WebSocket upgrade requests meant for the admin/health paths
    const reqPath = (req.url || '/').split('?')[0];
    if (reqPath === '/admin' || reqPath === '/health') {
        ws.close();
        return;
    }

    // Extract room code from URL path: /ABC123 → "ABC123"
    const room = reqPath.replace(/^\//, '').toUpperCase().trim();

    if (!room || room.length < 1) {
        ws.close(1008, 'Room code required in URL path.');
        return;
    }

    // Mark alive for ping/pong
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    // Join the room
    if (!rooms.has(room)) {
        rooms.set(room, { peers: new Set(), createdAt: Date.now(), peakPeers: 0, totalJoined: 0 });
    }
    const roomData = rooms.get(room);
    const { peers } = roomData;
    peers.add(ws);
    roomData.totalJoined++;
    if (peers.size > roomData.peakPeers) roomData.peakPeers = peers.size;

    console.log(`[+] Peer joined room "${room}" — room now has ${peers.size} peer(s)`);

    // Relay messages to all OTHER peers in the same room
    ws.on('message', (data, isBinary) => {
        peers.forEach((peer) => {
            if (peer !== ws && peer.readyState === 1 /* OPEN */) {
                peer.send(data, { binary: isBinary });
            }
        });
    });

    // Clean up on disconnect
    ws.on('close', () => {
        peers.delete(ws);
        console.log(`[-] Peer left room "${room}" — room now has ${peers.size} peer(s)`);
        if (peers.size === 0) {
            const { createdAt, peakPeers, totalJoined } = rooms.get(room);
            // Save to history
            sessionHistory.push({
                code: room,
                peakPeers,
                totalJoined,
                durationMs: Date.now() - createdAt,
                endedAt: Date.now(),
            });
            if (sessionHistory.length > SESSION_HISTORY_LIMIT) {
                sessionHistory.shift();
            }
            rooms.delete(room);
            console.log(`[~] Room "${room}" deleted (empty) — peak: ${peakPeers}, joined: ${totalJoined}`);
        }
    });

    ws.on('error', (err) => {
        console.error(`[!] WebSocket error in room "${room}":`, err.message);
    });
});

httpServer.listen(PORT, () => {
    console.log(`RJ Music Jam Server listening on port ${PORT}`);
    console.log(`Health: http://localhost:${PORT}/health`);
    console.log(`Admin:  http://localhost:${PORT}/admin`);
});
