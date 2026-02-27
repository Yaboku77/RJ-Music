/**
 * Musify Jam Session – WebSocket Server
 *
 * Rooms are identified by the session code in the URL path.
 * e.g. ws://yourhost:8080/ABC123
 *
 * Messages are broadcast to all OTHER peers in the same room.
 * The server does NOT interpret or modify messages — it only relays them.
 *
 * Deploy: any Node.js host (Railway, Render, Fly.io, VPS, etc.)
 * Run:    node server.js
 * Port:   8080 (override with PORT env variable)
 */

const { WebSocketServer } = require('ws');
const http = require('http');

const PORT = process.env.PORT || 8080;

// rooms: Map<roomCode, Set<WebSocket>>
const rooms = new Map();

// --- HTTP server (for health checks / uptime monitors) ---
const httpServer = http.createServer((req, res) => {
    if (req.url === '/health') {
        const roomCount = rooms.size;
        const peerCount = [...rooms.values()].reduce((n, r) => n + r.size, 0);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok', rooms: roomCount, peers: peerCount }));
        return;
    }
    res.writeHead(200);
    res.end('Musify Jam Server running');
});

// --- WebSocket server ---
const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws, req) => {
    // Extract room code from URL path: /ABC123 → "ABC123"
    const room = (req.url || '/').replace(/^\//, '').toUpperCase().trim();

    if (!room || room.length < 1) {
        ws.close(1008, 'Room code required in URL path.');
        return;
    }

    // Join the room
    if (!rooms.has(room)) rooms.set(room, new Set());
    const peers = rooms.get(room);
    peers.add(ws);

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
            rooms.delete(room);
            console.log(`[~] Room "${room}" deleted (empty)`);
        }
    });

    ws.on('error', (err) => {
        console.error(`[!] WebSocket error in room "${room}":`, err.message);
    });
});

httpServer.listen(PORT, () => {
    console.log(`Musify Jam Server listening on port ${PORT}`);
    console.log(`Health check: http://localhost:${PORT}/health`);
});
