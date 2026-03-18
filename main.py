import flet as ft
import sys
import os
import traceback
import time
import threading

# Global variables for engines
cbz_to_pdf_engine = None
cbz_to_epub_engine = None

def main(page):
    try:
        # E-ink Optimized App configuration
        page.title = "ComicToEink"
        page.scroll = "auto"
        page.theme_mode = ft.ThemeMode.LIGHT
        page.padding = 10
        page.bgcolor = "white"
        
        # Global State
        state = {
            "current_path": "",
            "selected_items": set(),
            "output_format": "epub", # default to epub for kindle
            "compress_enabled": False,
            "manga_mode": False,
            "server_running": False,
            "view_mode": "external", # 'external' for Import, 'internal' for Convert
            "library_display_mode": "list", # 'list', 'grid', 'cover'
            "discovered_peers": {}, # name -> {"ip": ip, "port": port, "alias": name}
            # Background Task Monitor State
            "monitor_active": False,
            "monitor_title": "",
            "monitor_message": "STANDING BY",
            "monitor_progress": 0.0,
            "monitor_success": 0,
            "monitor_fail": 0,
            "monitor_total": 0,
            "show_report": False
        }
        
        # Initialize internal storage directory
        base_dir = os.path.dirname(os.path.abspath(__file__))
        comic_library_dir = os.path.join(base_dir, "comic_library")
        os.makedirs(comic_library_dir, exist_ok=True)
        downloads_dir = os.path.join(base_dir, "webapp", "downloads")
        os.makedirs(downloads_dir, exist_ok=True)
        thumbnails_dir = os.path.join(base_dir, ".cache", "thumbnails")
        os.makedirs(thumbnails_dir, exist_ok=True)
        
        # Thumbnail Extractor
        def get_thumbnail(cbz_path):
            import zipfile, hashlib
            try:
                # Use a hash of the filepath plus modification time for robust caching
                file_hash = hashlib.md5(f"{cbz_path}_{os.path.getmtime(cbz_path)}".encode()).hexdigest()
                thumb_path = os.path.join(thumbnails_dir, f"{file_hash}.jpg")
                
                if os.path.exists(thumb_path):
                    return thumb_path
                    
                with zipfile.ZipFile(cbz_path, 'r') as zf:
                    image_files = sorted([f for f in zf.namelist() if f.lower().endswith(('.jpg', '.jpeg', '.png', '.webp'))])
                    if image_files:
                        with zf.open(image_files[0]) as source, open(thumb_path, 'wb') as target:
                            target.write(source.read())
                        return thumb_path
            except: pass
            return None
        
        # Initialize engines
        import cbz_to_pdf
        import cbz_to_epub
        global cbz_to_pdf_engine
        global cbz_to_epub_engine
        cbz_to_pdf_engine = cbz_to_pdf.convert_cbz_to_pdf
        cbz_to_epub_engine = cbz_to_epub.convert_cbz_to_epub

        # --- UNIFIED BATCH LIBRARY UI ---
        def get_android_drives():
            drives = {"/storage/emulated/0"}
            try:
                with open("/proc/mounts", "r") as f:
                    for line in f:
                        parts = line.split()
                        if len(parts) > 1:
                            mount = parts[1]
                            if mount.startswith("/storage") and mount != "/storage":
                                if "self" not in mount and "emulated" not in mount:
                                    drives.add(mount)
            except: pass
            return sorted(list(drives))

        # Removed FilePicker permanently to fix Android RSOD.
        # We now use the custom native file browser entirely.

        # Enterprise Android 13+ SD Card Access Handler using PyJNIus
        def request_sd_access(e=None):
            try:
                from jnius import autoclass, cast
                
                # Get Android classes
                Environment = autoclass('android.os.Environment')
                Intent = autoclass('android.content.Intent')
                Settings = autoclass('android.provider.Settings')
                Uri = autoclass('android.net.Uri')
                PythonActivity = autoclass('org.kivy.android.PythonActivity')
                
                # Check if we already have the Manage External Storage permission
                if not Environment.isExternalStorageManager():
                    # Create Intent to open the "All Files Access" settings page for our app
                    currentActivity = cast('android.app.Activity', PythonActivity.mActivity)
                    intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    
                    # Set the URI to specifically point to our package
                    uri = Uri.parse("package:" + currentActivity.getPackageName())
                    intent.setData(uri)
                    
                    # Start the settings activity
                    currentActivity.startActivity(intent)
                    
                    if e:
                        page.snack_bar = ft.SnackBar(ft.Text("Opening Android Settings. Please toggle 'Allow access to manage all files' on."), open=True)
                        page.update()
                else:
                    if e:
                        page.snack_bar = ft.SnackBar(ft.Text("Storage access is already granted!"), open=True)
                        page.update()
            except ImportError:
                # We are likely running on Desktop/iOS where jnius isn't available
                if e:
                    page.snack_bar = ft.SnackBar(ft.Text("Native Android storage permissions are only required on Android devices."), open=True)
                    page.update()
            except Exception as err:
                if e:
                    page.snack_bar = ft.SnackBar(ft.Text(f"Failed to request permission mapping: {err}"), open=True)
                    page.update()

        def render_ui():
            try:
                page.clean()
                
                def eink_button(text, on_click, expand=False, is_primary=False, disabled=False):
                    bgcolor = "black" if is_primary else "white"
                    color = "white" if is_primary else "black"
                    if disabled:
                        bgcolor = "#EEEEEE"
                        color = "grey"
                    return ft.Container(
                        content=ft.Text(text, size=20, weight="w900", color=color, text_align="center"),
                        on_click=on_click if not disabled else None,
                        bgcolor=bgcolor,
                        border=ft.border.all(3, "black" if not disabled else "grey"),
                        padding=20,
                        border_radius=0, 
                        ink=not disabled,
                        expand=expand
                    )

                # Format Toggles
                format_radios = ft.RadioGroup(
                    content=ft.Row([
                        ft.Radio(value="epub", label="EPUB (Kindle)"),
                        ft.Radio(value="pdf", label="PDF (Universal)")
                    ]),
                    value=state["output_format"],
                    on_change=lambda e: (state.update({"output_format": e.control.value}), render_ui())
                )

                sw_optimize = ft.Switch(
                    label="Optimize for E-ink", 
                    value=state["compress_enabled"], 
                    on_change=lambda e: state.update({"compress_enabled": e.control.value}),
                    active_color="black"
                )
                
                sw_manga = ft.Switch(
                    label="Manga Mode [EPUB]", 
                    value=state["manga_mode"],
                    on_change=lambda e: state.update({"manga_mode": e.control.value}),
                    visible=(state["output_format"] == "epub"),
                    active_color="black"
                )

                settings_col = ft.Column([
                    ft.Text("SETTINGS", size=18, weight="w900"),
                    format_radios, sw_optimize, sw_manga,
                    ft.Container(
                        content=ft.Text("GRANT ALL FILES ACCESS (SD CARD)", size=12, weight="w900", color="white", text_align="center"),
                        on_click=request_sd_access,
                        bgcolor="black",
                        padding=8,
                        visible=("android" in sys.platform.lower() or "linux" in sys.platform.lower()) # Show on Android builds
                    )
                ])
                
                # E-Ink Optimized View Mode Toggle
                def on_mode_change(new_mode):
                    if state["view_mode"] == new_mode: return
                    state["view_mode"] = new_mode
                    state["selected_items"].clear()
                    
                    if state["view_mode"] == "external":
                        # Request generic file access for SD cards before opening browser
                        request_sd_access()
                        # Start at DRIVES level instead of launching crash-prone FilePicker
                        state["current_path"] = "DRIVES"
                    else:
                        state["current_path"] = comic_library_dir
                        
                    render_ui()
                    
                mode_toggle = ft.Row([
                    ft.Container(
                        content=ft.Text("IMPORT NEW COMICS", size=16, weight="w900", color="white" if state["view_mode"] == "external" else "black", text_align="center"),
                        on_click=lambda _: on_mode_change("external"),
                        bgcolor="black" if state["view_mode"] == "external" else "white",
                        border=ft.border.all(3, "black"),
                        padding=12,
                        expand=True,
                        ink=True
                    ),
                    ft.Container(
                        content=ft.Text("LIBRARY [CONVERT]", size=16, weight="w900", color="white" if state["view_mode"] == "internal" else "black", text_align="center"),
                        on_click=lambda _: on_mode_change("internal"),
                        bgcolor="black" if state["view_mode"] == "internal" else "white",
                        border=ft.border.all(3, "black"),
                        padding=12,
                        expand=True,
                    )
                ], spacing=0)

                # Library Display Mode Toggle (Only visible in internal mode)
                display_mode_toggle = ft.Container()
                if state["view_mode"] == "internal" and state["current_path"] == comic_library_dir:
                    def on_display_change(e):
                        state["library_display_mode"] = e.control.selected_index
                        render_ui()
                        
                    display_mode_toggle = ft.Container(
                        content=ft.CupertinoSlidingSegmentedButton(
                            selected_index=({"list": 0, "grid": 1, "cover": 2}).get(state["library_display_mode"], 0),
                            controls=[
                                ft.Text("List"),
                                ft.Text("Grid"),
                                ft.Text("Cover")
                            ],
                            on_change=lambda e: (state.update({"library_display_mode": ["list", "grid", "cover"][int(e.data)]}), render_ui())
                        ),
                        padding=10,
                        alignment=ft.alignment.center
                    )

                # Wi-Fi Server
                def get_local_ip():
                    import socket
                    try:
                        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        s.connect(("8.8.8.8", 80))
                        ip = s.getsockname()[0]
                        s.close()
                        return ip
                    except: return "127.0.0.1"

                server_url_txt = ft.Text("SERVER ACTIVE" if state["server_running"] else "", color="black", weight="w900", size=16, text_align="center")
                
                def toggle_server(e):
                    global web_server
                    if not state["server_running"]:
                        server_url_txt.value = "STARTING MEDIA SERVER..."
                        page.update()
                        def run_server_task(e=None):
                            global web_server
                            global zc, zc_info
                            try:
                                import sys, os, socket
                                from zeroconf import ServiceInfo, Zeroconf
                                webapp_path = os.path.join(os.path.dirname(__file__), "webapp")
                                if webapp_path not in sys.path: sys.path.append(webapp_path)
                                from app import app as flask_app
                                from werkzeug.serving import make_server
                                web_server = make_server('0.0.0.0', 5000, flask_app)
                                state["server_running"] = True
                                ip = get_local_ip()
                                
                                try:
                                    zc = Zeroconf()
                                    hostname = socket.gethostname() or "AndroidNode"
                                    desc = {'alias': 'Inksync Android E-Ink'}
                                    zc_info = ServiceInfo(
                                        "_inksync._tcp.local.",
                                        f"{hostname}._inksync._tcp.local.",
                                        addresses=[socket.inet_aton(ip)],
                                        port=5000,
                                        properties=desc,
                                        server=f"{hostname}.local.",
                                    )
                                    zc.register_service(zc_info)
                                    
                                    class PeerListener:
                                        def remove_service(self, z, type_, name):
                                            if name in state.get("discovered_peers", {}):
                                                del state["discovered_peers"][name]
                                                try: render_ui()
                                                except: pass
                                                
                                        def update_service(self, z, type_, name): pass
                                        
                                        def add_service(self, z, type_, name):
                                            info = z.get_service_info(type_, name)
                                            if info and hostname not in name:
                                                peer_ip = socket.inet_ntoa(info.addresses[0])
                                                alias = info.properties.get(b'alias', b'').decode('utf-8') if info.properties and b'alias' in info.properties else name.replace('._inksync._tcp.local.', '')
                                                state.setdefault("discovered_peers", {})[name] = {"ip": peer_ip, "port": info.port, "alias": alias}
                                                try: render_ui()
                                                except: pass

                                    from zeroconf import ServiceBrowser
                                    global zc_browser
                                    state["discovered_peers"] = {}
                                    zc_browser = ServiceBrowser(zc, "_inksync._tcp.local.", PeerListener())
                                except Exception as zc_err:
                                    print(f"Zeroconf error: {zc_err}")

                                server_url_txt.value = f"SERVER ACTIVE AT:\nhttp://{ip}:5000\n(mDNS LocalSend READY)"
                                btn_server.content.value = "STOP WI-FI SERVER"
                                page.update()
                                
                                # serve_forever is blocking, so the UI must update strictly BEFORE this fires
                                # We launch it via an entirely separate generic thread so it doesn't block Flet's run_task
                                import threading
                                threading.Thread(target=web_server.serve_forever, daemon=True).start()

                            except Exception as err:
                                state["server_running"] = False
                                server_url_txt.value = f"SERVER ERROR: {err}"
                                btn_server.content.value = "START WI-FI SERVER"
                                page.update()
                                
                        page.run_task(run_server_task)
                    else:
                        try:
                            web_server.shutdown()
                            global zc, zc_info, zc_browser
                            if 'zc' in globals() and zc is not None:
                                try:
                                    if 'zc_browser' in globals() and zc_browser is not None:
                                        zc_browser.cancel()
                                        zc_browser = None
                                    zc.unregister_service(zc_info)
                                    zc.close()
                                except: pass
                                zc = None
                                state["discovered_peers"] = {}

                            state["server_running"] = False
                            server_url_txt.value = "SERVER STOPPED"
                            btn_server.content.value = "START WI-FI SERVER"
                            page.update()
                        except Exception as err:
                            server_url_txt.value = f"STOP ERROR: {err}"
                            page.update()
                            
                btn_server = eink_button("STOP WI-FI SERVER" if state["server_running"] else "START WI-FI SERVER", on_click=toggle_server, expand=True)

                # Batch Converter Logic removed, replaced by dynamic state tracker
                # --- OUTGOING P2P SEND UI ---
                peers_controls = []
                if state["server_running"] and state.get("discovered_peers"):
                    peers_controls.append(ft.Text("DISCOVERED DEVICES (TAP TO SEND QUEUE):", size=16, weight="w900"))
                    for peer_name, peer_data in state["discovered_peers"].items():
                        def send_to_peer(e, p_data=peer_data):
                            if not state["selected_items"]:
                                state["monitor_active"] = False
                                state["monitor_title"] = "Selection Empty"
                                state["monitor_message"] = "PLEASE STAGE FILES TO SEND FIRST."
                                state["show_report"] = True
                                page.update()
                                return
                            
                            state["monitor_active"] = True
                            state["monitor_message"] = f"CONNECTING TO {p_data['alias'].upper()}..."
                            state["monitor_progress"] = 0.0
                            page.update()
                            
                            def s_worker():
                                try:
                                    import requests, uuid
                                    
                                    # List of dicts: {"abs_path": ..., "rel_path": ...}
                                    files_to_send = []
                                    for p in list(state["selected_items"]):
                                        if os.path.isdir(p):
                                            parent_folder_name = os.path.basename(p)
                                            for root, _, files in os.walk(p):
                                                for f in files:
                                                    if f.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                                        abs_path = os.path.join(root, f)
                                                        # e.g. root = "/storage/Manga/Bleach/Vol1", p = "/storage/Manga/Bleach"
                                                        # relative_to_selected = "Vol1/file.cbz"
                                                        rel_to_p = os.path.relpath(abs_path, p)
                                                        # final logical path: "Bleach/Vol1/file.cbz"
                                                        logical_path = os.path.join(parent_folder_name, rel_to_p).replace('\\', '/')
                                                        files_to_send.append({"abs_path": abs_path, "rel_path": logical_path})
                                        elif os.path.isfile(p):
                                            if p.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                                files_to_send.append({"abs_path": p, "rel_path": os.path.basename(p)})
                                            
                                    total_send = len(files_to_send)
                                    if total_send == 0:
                                        state["monitor_active"] = False
                                        state["monitor_message"] = "NO VALID FILES TO SEND."
                                        page.update()
                                        return
                                        
                                    s_count = 0
                                    f_count = 0
                                    for idx, send_data in enumerate(files_to_send):
                                        s_path = send_data["abs_path"]
                                        s_rel_path = send_data["rel_path"]
                                        s_name = os.path.basename(s_path)
                                        
                                        state["monitor_message"] = f"[{idx+1}/{total_send}] SENDING {s_name.upper()}..."
                                        state["monitor_progress"] = (idx+1)/total_send
                                        page.update()
                                        
                                        upload_url = f"http://{p_data['ip']}:{p_data['port']}/upload/{uuid.uuid4().hex}"
                                        headers = {
                                            'X-File-Name': s_name,
                                            'X-Relative-Path': s_rel_path
                                        }
                                        
                                        try:
                                            with open(s_path, 'rb') as vf:
                                                resp = requests.post(upload_url, data=vf, headers=headers)
                                                if resp.status_code == 200:
                                                    s_count += 1
                                                else:
                                                    f_count += 1
                                        except:
                                            f_count += 1
                                                
                                    state["monitor_active"] = False
                                    state["monitor_success"] = s_count
                                    state["monitor_fail"] = f_count
                                    state["monitor_total"] = total_send
                                    state["monitor_title"] = "Transmission Complete"
                                    state["monitor_message"] = f"Delivered {s_count} items.\nFailed {f_count} items."
                                    state["show_report"] = True
                                    page.update()
                                except Exception as err:
                                    state["monitor_active"] = False
                                    state["monitor_title"] = "Transfer Error"
                                    state["monitor_message"] = str(err).upper()
                                    state["show_report"] = True
                                    page.update()
                                    
                            import threading
                            threading.Thread(target=s_worker, daemon=True).start()
                            
                        peers_controls.append(eink_button(f"SEND TO {peer_data['alias'].upper()}", on_click=send_to_peer, expand=True, is_primary=True))
                
                peers_col = ft.Column(peers_controls) if peers_controls else ft.Container()

                def run_convert(e):
                    if not state["selected_items"]: return
                    
                    state["monitor_active"] = True
                    state["monitor_message"] = "GATHERING FILES..."
                    state["monitor_progress"] = 0.0
                    page.update()
                    
                    selected_paths = list(state["selected_items"])
                    
                    def worker():
                        try:
                            # 1. Expand Directories into individual files (Convert Mode)
                            files_to_process = []
                            for p in selected_paths:
                                if os.path.isdir(p):
                                    for root, _, files in os.walk(p):
                                        for f in files:
                                            if f.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                                files_to_process.append(os.path.join(root, f))
                                elif os.path.isfile(p) and p.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                    files_to_process.append(p)
                                    
                            total_files = len(files_to_process)
                            if total_files == 0:
                                state["monitor_active"] = False
                                state["monitor_message"] = "NO VALID COMICS FOUND IN SELECTION."
                                page.update()
                                return
                                
                            base_dir = os.path.dirname(os.path.abspath(__file__))
                            downloads_dir = os.path.join(base_dir, "webapp", "downloads")
                            os.makedirs(downloads_dir, exist_ok=True)
                            
                            success_count = 0
                            fail_count = 0
                            for idx, src in enumerate(files_to_process):
                                # Update global status text to show overall batch progress
                                src_filename = os.path.basename(src)
                                state["monitor_message"] = f"[{idx+1}/{total_files}] PREPPING {src_filename.upper()}..."
                                page.update()
                                
                                out_ext = f".{state['output_format']}"
                                out_filename = src_filename.replace(".cbz", out_ext).replace(".cbr", out_ext).replace(".CBZ", out_ext).replace(".CBR", out_ext)
                                dst = os.path.join(downloads_dir, out_filename)
                                
                                # Callback wrapper to prepend batch status
                                def batch_progress(p, msg):
                                    state["monitor_progress"] = p/100
                                    state["monitor_message"] = f"[{idx+1}/{total_files}] {int(p)}% | {msg.upper()}"
                                    page.update()
                                
                                try:
                                    res = False
                                    if state["output_format"] == "pdf":
                                        res = cbz_to_pdf_engine(src, dst, progress_callback=batch_progress, compress=state["compress_enabled"], max_size_mb=None)
                                    elif state["output_format"] == "epub":
                                        res = cbz_to_epub_engine(src, dst, manga_mode=state["manga_mode"], optimize=state["compress_enabled"], progress_callback=batch_progress)
                                    
                                    if res: success_count += 1
                                    else: fail_count += 1
                                except Exception as inner_e:
                                    print(f"Skipping {src} due to error: {inner_e}")
                                    fail_count += 1
                            
                            state["monitor_active"] = False
                            state["monitor_success"] = success_count
                            state["monitor_fail"] = fail_count
                            state["monitor_total"] = total_files
                            state["monitor_title"] = "Conversion Complete"
                            state["monitor_message"] = f"Converted {success_count} items.\nFailed {fail_count} items."
                            state["show_report"] = True
                            
                            # Clear selection after successful batch processing
                            state["selected_items"].clear()
                            
                            page.update()
                            time.sleep(1.5)
                            render_ui() # Refresh the UI to reflect cleared checkboxes
                            
                        except Exception as err:
                            state["monitor_active"] = False
                            state["monitor_title"] = "Batch Error"
                            state["monitor_message"] = str(err).upper()
                            state["show_report"] = True
                            page.update()
                            
                    import threading
                    threading.Thread(target=worker).start()

                def run_import(e):
                    if not state["selected_items"]: return
                    
                    state["monitor_active"] = True
                    state["monitor_message"] = "IMPORTING FILES..."
                    state["monitor_progress"] = 0.0
                    page.update()
                    
                    selected_paths = list(state["selected_items"])
                    
                    def worker():
                        try:
                            import shutil
                            # 1. Expand Directories into individual files
                            files_to_process = []
                            for p in selected_paths:
                                if os.path.isdir(p):
                                    for root, _, files in os.walk(p):
                                        for f in files:
                                            if f.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                                files_to_process.append(os.path.join(root, f))
                                elif os.path.isfile(p) and p.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                    files_to_process.append(p)
                                    
                            total_files = len(files_to_process)
                            if total_files == 0:
                                state["monitor_active"] = False
                                state["monitor_message"] = "NO VALID COMICS FOUND IN SELECTION."
                                page.update()
                                return
                                
                            success_count = 0
                            fail_count = 0
                            new_selected = set()
                            for idx, src in enumerate(files_to_process):
                                src_filename = os.path.basename(src)
                                state["monitor_message"] = f"[{idx+1}/{total_files}] IMPORTING {src_filename.upper()}..."
                                state["monitor_progress"] = (idx+1)/total_files
                                page.update()
                                
                                # Extract parent folder to maintain series grouping
                                parent_name = os.path.basename(os.path.dirname(src))
                                target_dir = os.path.join(comic_library_dir, parent_name)
                                os.makedirs(target_dir, exist_ok=True)
                                
                                dst = os.path.join(target_dir, src_filename)
                                new_selected.add(dst)
                                try:
                                    if not os.path.exists(dst):
                                        file_size = os.path.getsize(src)
                                        copied_size = 0
                                        chunk_size = 1024 * 1024 # 1MB chunks
                                        with open(src, 'rb') as fsrc:
                                            with open(dst, 'wb') as fdst:
                                                while True:
                                                    buf = fsrc.read(chunk_size)
                                                    if not buf:
                                                        break
                                                    fdst.write(buf)
                                                    copied_size += len(buf)
                                                    
                                                    # UI Update during heavy copy
                                                    perc = copied_size / file_size if file_size > 0 else 1.0
                                                    mb_copied = copied_size / (1024 * 1024)
                                                    mb_total = file_size / (1024 * 1024)
                                                    state["monitor_message"] = f"[{idx+1}/{total_files}] COPYING {src_filename.upper()}... {mb_copied:.1f}MB / {mb_total:.1f}MB ({int(perc*100)}%)"
                                                    state["monitor_progress"] = perc
                                                    page.update()
                                                    
                                    success_count += 1
                                except Exception as inner_e:
                                    print(f"Skipping {src} setup due to error: {inner_e}")
                                    fail_count += 1
                            
                            state["monitor_active"] = False
                            state["monitor_success"] = success_count
                            state["monitor_fail"] = fail_count
                            state["monitor_total"] = total_files
                            state["monitor_title"] = "Import Complete"
                            state["monitor_message"] = f"Successfully imported {success_count} item(s).\nFailed {fail_count} item(s)."
                            state["show_report"] = True
                            
                            state["view_mode"] = "internal"
                            state["current_path"] = comic_library_dir
                            state["selected_items"] = new_selected
                            
                            page.update()
                            time.sleep(1.5)
                            render_ui()
                            
                        except Exception as err:
                            state["monitor_active"] = False
                            state["monitor_title"] = "Import Error"
                            state["monitor_message"] = str(err).upper()
                            state["show_report"] = True
                            page.update()
                            
                    import threading
                    threading.Thread(target=worker).start()

                def count_comics():
                    count = 0
                    for p in state["selected_items"]:
                        if os.path.isdir(p):
                            try:
                                for root, _, files in os.walk(p):
                                    for f in files:
                                        if f.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                            count += 1
                            except: pass
                        elif os.path.isfile(p) and p.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                            count += 1
                    return count
                    
                total_comics = count_comics()
                total_comics = count_comics()
                if state["selected_items"] and total_comics == 0:
                    convert_btn_text = "0 COMICS FOUND"
                elif total_comics > 0:
                    verb = "IMPORT" if state["view_mode"] == "external" else "CONVERT"
                    convert_btn_text = f"{verb} {total_comics} COMIC(S) [QUEUED]"
                else:
                    verb = "IMPORT" if state["view_mode"] == "external" else "CONVERT"
                    convert_btn_text = f"SELECT COMICS TO {verb}"
                    
                target_action = run_import if state["view_mode"] == "external" else run_convert
                btn_convert = eink_button(convert_btn_text, on_click=target_action, expand=True, is_primary=True, disabled=total_comics==0)

                # --- NATIVE FILE BROWSER ---
                def navigate(path):
                    state["current_path"] = path
                    render_ui()
                    
                def toggle_selection(path, is_selected):
                    if is_selected:
                        state["selected_items"].add(path)
                    else:
                        state["selected_items"].discard(path)
                    render_ui()

                def list_item(text, icon, full_path, is_dir=False, is_file=False):
                    is_selected = full_path in state["selected_items"]
                    display_mode = state.get("library_display_mode", "list") if state["view_mode"] == "internal" and state["current_path"] == comic_library_dir else "list"
                    
                    def on_check(e):
                        toggle_selection(full_path, e.control.value)
                        
                    def on_row_click(e):
                        if is_dir: navigate(full_path)
                        elif is_file: toggle_selection(full_path, not is_selected)
                        
                    if display_mode in ["grid", "cover"] and is_file and full_path.lower().endswith(('.cbz', '.cbr')):
                        thumb_path = get_thumbnail(full_path)
                        img_content = ft.Image(src=thumb_path, fit=ft.ImageFit.COVER) if thumb_path else ft.Container(bgcolor="grey")
                        
                        return ft.Container(
                            content=ft.Stack([
                                img_content,
                                ft.Container(
                                    content=ft.Text(text, size=12, color="white", weight="w900", no_wrap=True, text_align="center"),
                                    bgcolor=ft.colors.with_opacity(0.7, "black"),
                                    alignment=ft.alignment.bottom_center,
                                    bottom=0, left=0, right=0, padding=4
                                ),
                                ft.Container(
                                    content=ft.Checkbox(value=is_selected, on_change=on_check, active_color="black"),
                                    top=4, right=4
                                )
                            ]),
                            on_click=on_row_click,
                            bgcolor="black",
                            border=ft.border.all(4 if is_selected else 2, "black" if is_selected else "transparent"),
                            border_radius=8,
                            clip_behavior=ft.ClipBehavior.HARD_EDGE,
                            ink=True
                        )
                        
                    return ft.Container(
                        content=ft.Row([
                            ft.Checkbox(value=is_selected, on_change=on_check, active_color="black"),
                            ft.Text(icon, size=24),
                            ft.Text(text, size=20, weight="w900" if is_dir else "w700", color="white" if is_file else "black", no_wrap=True, expand=True)
                        ]),
                        on_click=on_row_click,
                        bgcolor="black" if is_file else "white",
                        border=ft.border.all(4 if is_selected else 2, "black"),
                        padding=15,
                        ink=True
                    )
                
                start_path = state["current_path"]
                display_mode = state.get("library_display_mode", "list") if state["view_mode"] == "internal" and start_path == comic_library_dir else "list"
                
                if display_mode == "grid":
                    file_list = ft.GridView(expand=True, runs_count=5, max_extent=160, child_aspect_ratio=0.7, spacing=10, run_spacing=10)
                elif display_mode == "cover":
                    file_list = ft.GridView(expand=True, runs_count=5, max_extent=280, child_aspect_ratio=0.7, spacing=15, run_spacing=15)
                else:
                    file_list = ft.Column(scroll="auto", expand=True, spacing=2)
                
                try:
                    start_path = state["current_path"]
                    
                    # --- Breadcrumb Navigation UI ---
                    if start_path != "DRIVES" and start_path != comic_library_dir:
                        path_parts = ["DRIVES"] + [p for p in start_path.split('/') if p]
                        breadcrumb_controls = []
                        for i, part in enumerate(path_parts):
                            target_path = "DRIVES" if i == 0 else "/" + "/".join(path_parts[1:i+1])
                            def make_breadcrumb_handler(tp):
                                return lambda _: navigate(tp)
                            
                            breadcrumb_controls.append(
                                ft.Container(
                                    content=ft.Text(part.upper(), size=14, weight="w900", color="white"),
                                    bgcolor="black", padding=8, ink=True, border_radius=4,
                                    on_click=make_breadcrumb_handler(target_path)
                                )
                            )
                            if i < len(path_parts) - 1:
                                breadcrumb_controls.append(ft.Text(">", size=14, weight="w900", color="black"))
                                
                        file_list.controls.append(
                            ft.Container(
                                content=ft.Row(breadcrumb_controls, scroll="auto"),
                                bgcolor="#EEEEEE", padding=10, border=ft.border.all(2, "black")
                            )
                        )
                    
                    if start_path == "DRIVES":
                        file_list.controls.append(ft.Text("QUICK ACCESS:", size=16, weight="w900", color="black"))
                        quick_folders = [
                            ("/storage/emulated/0/Download", "⬇️", "DOWNLOADS"),
                            ("/storage/emulated/0/Documents", "📄", "DOCUMENTS"),
                            ("/storage/emulated/0/DCIM", "📷", "PHOTOS/IMAGES"),
                            ("/storage/emulated/0/Pictures", "🖼️", "PICTURES")
                        ]
                        for f_path, icon, label in quick_folders:
                            if os.path.exists(f_path):
                                def make_quick_handler(tp):
                                    return lambda _: navigate(tp)
                                file_list.controls.append(
                                    ft.Container(
                                        content=ft.Row([ft.Text(icon, size=24), ft.Text(label, size=16, weight="w900")]),
                                        bgcolor="white", border=ft.border.all(2, "black"), padding=10, ink=True,
                                        on_click=make_quick_handler(f_path)
                                    )
                                )
                                
                        file_list.controls.append(ft.Text("ALL STORAGE DRIVES:", size=16, weight="w900", color="black"))
                        for drive in get_android_drives():
                            def make_drive_handler(tp):
                                return lambda _: navigate(tp)
                            file_list.controls.append(
                                ft.Container(
                                    content=ft.Row([ft.Text("💽", size=24), ft.Text(drive, size=16, weight="w900")]),
                                    bgcolor="white", border=ft.border.all(2, "black"), padding=10, ink=True,
                                    on_click=make_drive_handler(drive)
                                )
                            )
                    else:
                        try:
                            items = sorted(os.listdir(start_path))
                            for item in items:
                                full_path = os.path.join(start_path, item)
                                if os.path.isdir(full_path):
                                    # Modified Directory Listing: Clicking the row navigates, clicking the checkbox selects the folder for batch import.
                                    is_selected = full_path in state["selected_items"]
                                    
                                    def on_dir_check(e, p=full_path):
                                        toggle_selection(p, e.control.value)
                                        
                                    def on_dir_click(e, p=full_path):
                                        navigate(p)
                                        
                                    dir_row = ft.Container(
                                        content=ft.Row([
                                            ft.Checkbox(value=is_selected, on_change=on_dir_check, active_color="black"),
                                            ft.Text("📂", size=24),
                                            ft.Text(item, size=16, weight="w900", color="black", expand=True)
                                        ]),
                                        on_click=on_dir_click,
                                        bgcolor="white",
                                        border=ft.border.all(4 if is_selected else 2, "black"),
                                        padding=15,
                                        ink=True
                                    )
                                    file_list.controls.append(dir_row)
                                else:
                                    if item.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                        file_list.controls.append(list_item(item, "📄", full_path, is_file=True))
                                    else:
                                        if isinstance(file_list, ft.Column):
                                            file_list.controls.append(
                                                ft.Container(
                                                    content=ft.Row([
                                                        ft.Text("⚠️", size=24),
                                                        ft.Text(item[:30]+"..." if len(item)>30 else item, size=14, color="grey", no_wrap=True)
                                                    ]),
                                                    bgcolor="#EEEEEE",
                                                    border=ft.border.all(1, "grey"),
                                                    padding=10
                                                )
                                            )
                        except PermissionError:
                            file_list.controls.append(ft.Container(padding=20, content=ft.Text("PERMISSION DENIED.\nPLEASE GRANT ALL FILES ACCESS USING THE SETTINGS BUTTON ABOVE.", size=16, color="red", weight="w900", text_align="center")))
                except Exception as e:
                    file_list.controls.append(ft.Text(f"ACCESS DENIED: {e}", color="black", weight="w900"))

                # --- UI Tracker & Dialogs ---
                tracker_container = ft.Container()
                if state.get("monitor_active", False):
                    tracker_container = ft.Container(
                        content=ft.Column([
                            ft.Text("BACKGROUND PROCESSING", size=16, weight="w900", color="white", text_align="center"),
                            ft.Text(state.get("monitor_message", ""), size=14, color="white", text_align="center"),
                            ft.ProgressBar(value=state.get("monitor_progress", 0.0), color="white", bgcolor="grey", width=300)
                        ], horizontal_alignment=ft.CrossAxisAlignment.CENTER),
                        bgcolor="black",
                        padding=20,
                        border_radius=12,
                        border=ft.border.all(2, "white"),
                        margin=ft.margin.all(20),
                        shadow=ft.BoxShadow(spread_radius=1, blur_radius=15, color=ft.colors.with_opacity(0.5, "black"))
                    )
                
                # Final Layout construction
                main_column = ft.Column([
                    ft.Text("COMIC SYNC PRO", size=36, weight="w900", color="black"),
                    ft.Container(bgcolor="black", height=4),
                    settings_col,
                    ft.Container(bgcolor="black", height=2),
                    mode_toggle,
                    display_mode_toggle,
                    ft.Text(f"STAGED IN QUEUE: {len(state['selected_items'])} FILES (MULTI-FOLDER READY)\nDIR: {start_path}", color="black", size=14, weight="w900"),
                    ft.Container(content=file_list, height=400),
                    ft.Container(bgcolor="black", height=4),
                    ft.Row([btn_server, btn_convert]),
                    server_url_txt,
                    peers_col
                ], spacing=10, scroll=ft.ScrollMode.HIDDEN)
                
                # Use a Stack to ensure the loading tracker natively floats directly in the absolute center of the display
                content_stack = ft.Stack([
                    main_column
                ])
                
                if state.get("monitor_active", False):
                     # Add tracker on top
                     loading_overlay = ft.Container(
                         content=tracker_container,
                         alignment=ft.alignment.center,
                         expand=True
                     )
                     content_stack.controls.append(loading_overlay)
                
                page.add(
                    ft.Container(
                        content=content_stack,
                        padding=15,
                        border=ft.border.all(4, "black"),
                        expand=True
                    )
                )
                
                # Show completion dialog if flagged
                if state.get("show_report", False):
                    def close_dlg(e):
                        state["show_report"] = False
                        dlg.open = False
                        page.update()
                        
                    dlg = ft.AlertDialog(
                        title=ft.Text(state.get("monitor_title", "Report")),
                        content=ft.Text(state.get("monitor_message", "")),
                        actions=[ft.TextButton("OK", on_click=close_dlg)],
                        alignment=ft.alignment.center
                    )
                    page.dialog = dlg
                    dlg.open = True
                    
                page.update()
                
            except Exception as e:
                raise e

        # Initial Boot
        render_ui()

    except Exception as global_err:
        page.clean()
        error_msg = f"FATAL BOOT ERROR:\n{global_err}\n\n{traceback.format_exc()}"
        page.add(
            ft.Container(
                content=ft.Column([
                    ft.Text("APPLICATION CRASH", color="red", size=24, weight="w900"),
                    ft.Text(error_msg, color="black", size=14, selectable=True)
                ]),
                padding=20,
                border=ft.border.all(4, "red"),
                bgcolor="white"
            )
        )
        page.update()

if __name__ == "__main__":
    ft.app(target=main)
