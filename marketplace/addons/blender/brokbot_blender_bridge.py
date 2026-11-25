bl_info = {
    "name": "Brok Bot 3D Socket Bridge",
    "author": "Brok Bot Core Team",
    "version": (1, 0, 0),
    "blender": (3, 6, 0),
    "location": "View3D > Sidebar > Brok Bot",
    "description": "Local loopback TCP JSON-RPC 2.0 bridge (127.0.0.1:9876) for Brok Bot scene inspection, guarded bpy execution, and PNG viewport previews.",
    "category": "System",
}

import base64
import io
import json
import os
import queue
import socket
import tempfile
import threading
import traceback
from contextlib import redirect_stderr, redirect_stdout

try:
    import bpy  # type: ignore
except ImportError:  # Allows syntax check and headless testing outside Blender
    bpy = None


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 9876


class BrokBlenderBridgeServer:
    """Newline-delimited JSON-RPC 2.0 server listening strictly on 127.0.0.1."""

    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT) -> None:
        self.host = host
        self.port = port
        self._server_socket: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._running = False
        self._task_queue: queue.Queue[tuple[str, dict, queue.Queue]] = queue.Queue()

    @property
    def is_running(self) -> bool:
        return self._running

    def start(self) -> None:
        if self._running:
            return
        self._running = True
        self._server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server_socket.bind((self.host, self.port))
        self._server_socket.listen(8)
        self._server_socket.settimeout(0.5)

        self._thread = threading.Thread(
            target=self._accept_loop,
            name="BrokBotBlenderBridge",
            daemon=True,
        )
        self._thread.start()

        if bpy is not None:
            bpy.app.timers.register(self._drain_main_thread_queue, persistent=True)

    def stop(self) -> None:
        self._running = False
        if self._server_socket is not None:
            try:
                self._server_socket.close()
            except OSError:
                pass
            self._server_socket = None

    def _accept_loop(self) -> None:
        assert self._server_socket is not None
        while self._running:
            try:
                client_sock, _addr = self._server_socket.accept()
            except socket.timeout:
                continue
            except OSError:
                break

            worker = threading.Thread(
                target=self._handle_client,
                args=(client_sock,),
                daemon=True,
            )
            worker.start()

    def _handle_client(self, client_sock: socket.socket) -> None:
        with client_sock:
            reader = client_sock.makefile("r", encoding="utf-8", newline="\n")
            for raw_line in reader:
                line = raw_line.strip()
                if not line:
                    continue
                response = self._process_jsonrpc_line(line)
                payload = (json.dumps(response) + "\n").encode("utf-8")
                try:
                    client_sock.sendall(payload)
                except OSError:
                    break

    def _process_jsonrpc_line(self, line: str) -> dict:
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            method = request.get("method")
            params = request.get("params") or {}
            if not isinstance(method, str):
                raise ValueError("Missing or invalid JSON-RPC method")
            if not isinstance(params, dict):
                raise ValueError("JSON-RPC params must be a JSON object")

            result = self._dispatch_to_main_thread(method, params)
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": result,
            }
        except Exception as exc:  # noqa: BLE001
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32000,
                    "message": str(exc),
                    "data": traceback.format_exc(limit=4),
                },
            }

    def _dispatch_to_main_thread(self, method: str, params: dict) -> dict:
        if bpy is None:
            return self._execute_method(method, params)

        reply_queue: queue.Queue = queue.Queue(maxsize=1)
        self._task_queue.put((method, params, reply_queue))
        ok, payload = reply_queue.get(timeout=60.0)
        if not ok:
            raise RuntimeError(payload)
        return payload

    def _drain_main_thread_queue(self) -> float | None:
        if not self._running:
            return None
        while not self._task_queue.empty():
            method, params, reply_queue = self._task_queue.get_nowait()
            try:
                result = self._execute_method(method, params)
                reply_queue.put((True, result))
            except Exception as exc:  # noqa: BLE001
                reply_queue.put((False, f"{exc}\n{traceback.format_exc(limit=4)}"))
        return 0.05

    def _execute_method(self, method: str, params: dict) -> dict:
        if method == "blender_get_scene_info":
            return _handle_get_scene_info(params)
        if method == "blender_execute_script":
            return _handle_execute_script(params)
        if method == "blender_render_preview":
            return _handle_render_preview(params)
        raise ValueError(f"Unsupported Blender bridge method: {method}")


def _handle_get_scene_info(params: dict) -> dict:
    if bpy is None:
        return {"scene": "headless", "objects": [], "materials": []}

    include_materials = bool(params.get("includeMaterials", True))
    scene = bpy.context.scene
    objects = [
        {
            "name": obj.name,
            "type": obj.type,
            "location": [round(float(v), 4) for v in obj.location],
            "visible": bool(obj.visible_get()),
        }
        for obj in scene.objects
    ]
    cameras = [obj.name for obj in scene.objects if obj.type == "CAMERA"]
    lights = [obj.name for obj in scene.objects if obj.type == "LIGHT"]
    materials = [mat.name for mat in bpy.data.materials] if include_materials else []

    return {
        "scene": scene.name,
        "renderEngine": scene.render.engine,
        "resolution": {
            "width": int(scene.render.resolution_x),
            "height": int(scene.render.resolution_y),
        },
        "objectCount": len(objects),
        "objects": objects,
        "cameras": cameras,
        "lights": lights,
        "materials": materials,
    }


def _handle_execute_script(params: dict) -> dict:
    code = params.get("code")
    if not isinstance(code, str) or not code.strip():
        raise ValueError("Parameter 'code' must be a non-empty Python script string.")

    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()
    namespace = {"bpy": bpy, "__name__": "__brokbot__"}

    with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
        exec(compile(code, "<brokbot_bpy_script>", "exec"), namespace, namespace)  # noqa: S102

    return {
        "status": "ok",
        "stdout": stdout_buf.getvalue(),
        "stderr": stderr_buf.getvalue(),
    }


def _handle_render_preview(params: dict) -> dict:
    if bpy is None:
        raise RuntimeError("Blender bpy runtime is unavailable.")

    scene = bpy.context.scene
    width = int(params.get("width", scene.render.resolution_x or 1280))
    height = int(params.get("height", scene.render.resolution_y or 720))

    prev_x = scene.render.resolution_x
    prev_y = scene.render.resolution_y
    prev_format = scene.render.image_settings.file_format
    prev_path = scene.render.filepath

    temp_file = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    temp_path = temp_file.name
    temp_file.close()

    try:
        scene.render.resolution_x = max(64, min(width, 3840))
        scene.render.resolution_y = max(64, min(height, 2160))
        scene.render.image_settings.file_format = "PNG"
        scene.render.filepath = temp_path
        bpy.ops.render.render(write_still=True)

        with open(temp_path, "rb") as image_fp:
            raw_png = image_fp.read()

        return {
            "status": "ok",
            "mimeType": "image/png",
            "width": scene.render.resolution_x,
            "height": scene.render.resolution_y,
            "imageBase64": base64.b64encode(raw_png).decode("ascii"),
        }
    finally:
        scene.render.resolution_x = prev_x
        scene.render.resolution_y = prev_y
        scene.render.image_settings.file_format = prev_format
        scene.render.filepath = prev_path
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass


_BRIDGE_SERVER: BrokBlenderBridgeServer | None = None


def _get_server() -> BrokBlenderBridgeServer:
    global _BRIDGE_SERVER
    if _BRIDGE_SERVER is None:
        _BRIDGE_SERVER = BrokBlenderBridgeServer(DEFAULT_HOST, DEFAULT_PORT)
    return _BRIDGE_SERVER


if bpy is not None:
    class BROKBOT_OT_StartBridge(bpy.types.Operator):
        bl_idname = "brokbot.start_bridge"
        bl_label = "Start Brok Bot Bridge"

        def execute(self, context):
            server = _get_server()
            server.start()
            self.report({"INFO"}, f"Brok Bot bridge listening on {server.host}:{server.port}")
            return {"FINISHED"}


    class BROKBOT_OT_StopBridge(bpy.types.Operator):
        bl_idname = "brokbot.stop_bridge"
        bl_label = "Stop Brok Bot Bridge"

        def execute(self, context):
            _get_server().stop()
            self.report({"INFO"}, "Brok Bot bridge stopped")
            return {"FINISHED"}


    class BROKBOT_PT_SidebarPanel(bpy.types.Panel):
        bl_label = "Brok Bot Bridge"
        bl_idname = "BROKBOT_PT_sidebar_panel"
        bl_space_type = "VIEW_3D"
        bl_region_type = "UI"
        bl_category = "Brok Bot"

        def draw(self, context):
            layout = self.layout
            server = _get_server()
            layout.label(text=f"Endpoint: {server.host}:{server.port}")
            if server.is_running:
                layout.label(text="Status: Listening", icon="CHECKMARK")
                layout.operator("brokbot.stop_bridge", icon="PAUSE")
            else:
                layout.label(text="Status: Stopped", icon="X")
                layout.operator("brokbot.start_bridge", icon="PLAY")


    _CLASSES = (
        BROKBOT_OT_StartBridge,
        BROKBOT_OT_StopBridge,
        BROKBOT_PT_SidebarPanel,
    )


    def register():
        for cls in _CLASSES:
            bpy.utils.register_class(cls)
        _get_server().start()


    def unregister():
        _get_server().stop()
        for cls in reversed(_CLASSES):
            bpy.utils.unregister_class(cls)
