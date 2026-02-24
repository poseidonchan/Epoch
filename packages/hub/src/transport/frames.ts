import type { WebSocket } from "ws";

type SequencedState = {
  seq: number;
};

type OperatorSocketConn = {
  ws: WebSocket;
};

type BroadcastState = SequencedState & {
  operators: Iterable<OperatorSocketConn>;
};

export function sendResOk(ws: WebSocket, id: string, payload: any) {
  ws.send(JSON.stringify({ type: "res", id, ok: true, payload }));
}

export function sendResError(ws: WebSocket, id: string, code: string, message: string, data?: any) {
  ws.send(JSON.stringify({ type: "res", id, ok: false, error: { code, message, data } }));
}

export function sendEvent(ws: WebSocket, state: SequencedState, event: string, payload: any) {
  const seq = state.seq++;
  ws.send(JSON.stringify({ type: "event", event, payload, seq, ts: new Date().toISOString() }));
}

export function broadcastEvent(state: BroadcastState, event: string, payload: any) {
  for (const conn of state.operators) {
    sendEvent(conn.ws, state, event, payload);
  }
}
