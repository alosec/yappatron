"""WebSocket server for communicating with the Swift UI."""

import asyncio
import base64
import json
import struct
import threading
from enum import Enum
from typing import Callable

import numpy as np
import websockets
from websockets.server import serve


class MessageType(str, Enum):
    """Message types for UI communication."""
    
    # From engine to UI
    TEXT = "text"  # Full transcribed text to display/type
    SPEECH_START = "speech_start"
    SPEECH_END = "speech_end"
    STATUS = "status"
    
    # From UI to engine
    AUDIO = "audio"  # Audio chunk from Swift
    PAUSE = "pause"
    RESUME = "resume"


class JsonRpcServer:
    """WebSocket JSON-RPC server for UI communication.
    
    Receives audio from Swift, processes it, sends text back.
    """
    
    def __init__(self, host: str = "localhost", port: int = 9876):
        self.host = host
        self.port = port
        self.clients: set[websockets.WebSocketServerProtocol] = set()
        self._server = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._running = False
        
        # Callbacks
        self.on_audio_chunk: Callable[[np.ndarray], None] | None = None
        self.on_pause: Callable[[], None] | None = None
        self.on_resume: Callable[[], None] | None = None
        
        self.is_paused = False
    
    async def _handler(self, websocket: websockets.WebSocketServerProtocol):
        """Handle a WebSocket connection."""
        self.clients.add(websocket)
        print(f"Client connected. Total: {len(self.clients)}")
        
        try:
            async for message in websocket:
                await self._handle_message(websocket, message)
        except websockets.ConnectionClosed:
            pass
        finally:
            self.clients.discard(websocket)
            print(f"Client disconnected. Total: {len(self.clients)}")
    
    async def _handle_message(self, websocket, message: str):
        """Handle an incoming message."""
        try:
            data = json.loads(message)
            msg_type = data.get("type")
            
            if msg_type == MessageType.AUDIO:
                # Decode base64 audio data
                audio_b64 = data.get("data", "")
                sample_count = data.get("samples", 0)
                
                if audio_b64 and sample_count > 0:
                    audio_bytes = base64.b64decode(audio_b64)
                    # Convert bytes to float32 array
                    audio = np.frombuffer(audio_bytes, dtype=np.float32)
                    
                    if self.on_audio_chunk and not self.is_paused:
                        self.on_audio_chunk(audio)
            
            elif msg_type == MessageType.PAUSE:
                self.is_paused = True
                if self.on_pause:
                    self.on_pause()
            
            elif msg_type == MessageType.RESUME:
                self.is_paused = False
                if self.on_resume:
                    self.on_resume()
            
        except json.JSONDecodeError:
            pass  # Ignore invalid JSON (might be binary)
        except Exception as e:
            print(f"Error handling message: {e}")
    
    async def _broadcast(self, message: dict):
        """Broadcast a message to all connected clients."""
        if not self.clients:
            return
        
        data = json.dumps(message)
        await asyncio.gather(
            *[client.send(data) for client in self.clients],
            return_exceptions=True
        )
    
    def _run_server(self):
        """Run the server in a background thread."""
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        
        async def serve_forever():
            # Bind only to IPv4 localhost to avoid dual-stack issues
            async with serve(self._handler, "127.0.0.1", self.port) as server:
                self._server = server
                print(f"WebSocket server listening on ws://127.0.0.1:{self.port}")
                while self._running:
                    await asyncio.sleep(0.1)
        
        try:
            self._loop.run_until_complete(serve_forever())
        except Exception as e:
            print(f"WebSocket server error: {e}")
    
    def start(self):
        """Start the server."""
        if self._running:
            return
        
        self._running = True
        self._thread = threading.Thread(target=self._run_server, daemon=True)
        self._thread.start()
    
    def stop(self):
        """Stop the server."""
        self._running = False
        if self._loop:
            self._loop.call_soon_threadsafe(self._loop.stop)
        if self._thread:
            self._thread.join(timeout=2.0)
    
    def emit_text(self, text: str):
        """Emit transcribed text - UI should display and type this."""
        if self._loop:
            asyncio.run_coroutine_threadsafe(
                self._broadcast({"type": MessageType.TEXT, "text": text}),
                self._loop
            )
    
    def emit_speech_start(self):
        """Signal that speech started."""
        if self._loop:
            asyncio.run_coroutine_threadsafe(
                self._broadcast({"type": MessageType.SPEECH_START}),
                self._loop
            )
    
    def emit_speech_end(self):
        """Signal that speech ended."""
        if self._loop:
            asyncio.run_coroutine_threadsafe(
                self._broadcast({"type": MessageType.SPEECH_END}),
                self._loop
            )
    
    def emit_status(self, status: str):
        """Emit a status message."""
        if self._loop:
            asyncio.run_coroutine_threadsafe(
                self._broadcast({"type": MessageType.STATUS, "status": status}),
                self._loop
            )


# Backwards compatibility aliases
def emit_word(self, word: str):
    self.emit_text(word + " ")

def emit_char(self, char: str):
    self.emit_text(char)

def set_input_focused(self, focused: bool):
    self.is_input_focused = focused

JsonRpcServer.emit_word = emit_word
JsonRpcServer.emit_char = emit_char
JsonRpcServer.set_input_focused = set_input_focused
JsonRpcServer.is_input_focused = False
