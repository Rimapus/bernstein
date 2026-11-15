// Load test for result: 500 Socket.IO clients over WebSocket. They connect
// over RAMP seconds (30 by default), then all stay connected together for
// HOLD seconds (60 by default). Every client must receive score updates.
import { WebSocket } from 'k6/websockets';
import { setTimeout } from 'k6/timers';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const RESULT_URL = (__ENV.RESULT_URL || 'https://result.bernstein.local').replace(/^http/, 'ws');
const CLIENTS = Number(__ENV.CLIENTS || 500);
const RAMP_MS = Number(__ENV.RAMP || 30) * 1000;
const HOLD_MS = Number(__ENV.HOLD || 60) * 1000;
const scores = new Counter('scores_received');

export const options = {
  scenarios: {
    viewers: {
      executor: 'per-vu-iterations',
      vus: CLIENTS,
      iterations: 1,
      maxDuration: `${(RAMP_MS + HOLD_MS) / 1000 + 60}s`,
    },
  },
  thresholds: {
    checks: ['rate>0.99'],
    ws_connecting: ['p(95)<1000'],
  },
};

export default function () {
  // Spread the connections over the ramp, and close them all at the same time.
  const delay = ((__VU - 1) * RAMP_MS) / CLIENTS;
  sleep(delay / 1000);
  const ws = new WebSocket(`${RESULT_URL}/socket.io/?EIO=4&transport=websocket`);
  let received = 0;

  ws.onmessage = (event) => {
    const packet = String(event.data);
    if (packet.startsWith('0')) {
      ws.send('40'); // Engine.IO open: join the default Socket.IO namespace
    } else if (packet === '2') {
      ws.send('3'); // Engine.IO ping: answer or the server drops the client
    } else if (packet.startsWith('42["scores"')) {
      received += 1;
      scores.add(1);
    }
  };

  ws.onclose = () => {
    check(received, { 'received scores': (n) => n > 0 });
  };

  setTimeout(() => ws.close(), RAMP_MS + HOLD_MS - delay);
}
