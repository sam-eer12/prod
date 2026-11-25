# Brok Bot Blender 3D Bridge Addon

Local loopback TCP JSON-RPC 2.0 server (`127.0.0.1:9876`) that connects Blender to Brok Bot on macOS.

## Installation

1. Open **Blender 3.6+** and navigate to **Edit -> Preferences -> Add-ons**.
2. Click **Install...** and select `brokbot_blender_bridge.py`.
3. Enable **System: Brok Bot 3D Socket Bridge**.
4. Open the 3D Viewport sidebar (`N`) -> **Brok Bot** tab to confirm the server status (`127.0.0.1:9876`).

## Supported JSON-RPC 2.0 Methods

| Method | Approval Gate in Brok Bot | Description |
| :--- | :---: | :--- |
| `blender_get_scene_info` | Auto | Returns scene metadata, objects, cameras, lights, materials, and render resolution. |
| `blender_execute_script` | **Required** | Executes a user-approved `bpy` Python script safely on Blender's main thread. |
| `blender_render_preview` | Auto | Renders the active camera to PNG and returns `imageBase64` for inline display in chat. |
