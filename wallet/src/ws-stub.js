// rpc-websockets yerine geçen boş sınıf: cüzdan canlı WebSocket aboneliği kullanmaz (onaylar HTTP sorgusuyla alınır).
// Böylece LGPL lisanslı rpc-websockets pakete girmez.
export class CommonClient { constructor() {} on() { return this } once() { return this } off() { return this } removeAllListeners() { return this } emit() { return false } connect() {} close() {}
  call() { return Promise.reject(new Error("websocket disabled")) } notify() { return Promise.reject(new Error("websocket disabled")) } }
export function WebSocket() { throw new Error("websocket disabled") }
