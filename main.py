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
            "current_path": "/storage/emulated/0/Download",
            "selected_items": set(),
            "output_format": "epub", # default to epub for kindle
            "compress_enabled": False,
            "manga_mode": False,
            "server_running": False,
            "view_mode": "external", # 'external' for Import, 'internal' for Convert
            "library_display_mode": "list", # 'list', 'grid', 'cover'
            "discovered_peers": {} # name -> {"ip": ip, "port": port, "alias": name}
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
                    format_radios, sw_optimize, sw_manga
                ])
                
                # E-Ink Optimized View Mode Toggle
                def on_mode_change(new_mode):
                    if state["view_mode"] == new_mode: return
                    state["view_mode"] = new_mode
                    state["selected_items"].clear()
                    if state["view_mode"] == "external":
                        state["current_path"] = "/storage/emulated/0/Download"
                    else:
                        state["current_path"] = comic_library_dir
                    render_ui()
                    
                mode_toggle = ft.Row([
                    ft.Container(
                        content=ft.Text("SD CARD [IMPORT]", size=16, weight="w900", color="white" if state["view_mode"] == "external" else "black", text_align="center"),
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
                        status_txt.value = "STARTING MEDIA SERVER..."
                        page.update()
                        def run_server():
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
                                status_txt.value = "SERVER RUNNING"
                                page.update()
                                web_server.serve_forever()
                            except Exception as err:
                                state["server_running"] = False
                                status_txt.value = f"SERVER ERROR: {err}"
                                page.update()
                        import threading
                        threading.Thread(target=run_server, daemon=True).start()
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
                            server_url_txt.value = ""
                            btn_server.content.value = "START WI-FI SERVER"
                            status_txt.value = "SERVER STOPPED"
                            page.update()
                        except Exception as err:
                            status_txt.value = f"STOP ERROR: {err}"
                            page.update()
                            
                btn_server = eink_button("STOP WI-FI SERVER" if state["server_running"] else "START WI-FI SERVER", on_click=toggle_server, expand=True)

                # Batch Converter Logic
                progress_bar = ft.ProgressBar(width=300, visible=False, color="black", bgcolor="white")
                status_txt = ft.Text("STANDING BY", color="black", weight="w900", size=18)
                
                # --- OUTGOING P2P SEND UI ---
                peers_controls = []
                if state["server_running"] and state.get("discovered_peers"):
                    peers_controls.append(ft.Text("DISCOVERED DEVICES (TAP TO SEND QUEUE):", size=16, weight="w900"))
                    for peer_name, peer_data in state["discovered_peers"].items():
                        def send_to_peer(e, p_data=peer_data):
                            if not state["selected_items"]:
                                status_txt.value = "PLEASE STAGE FILES TO SEND FIRST."
                                page.update()
                                return
                            
                            status_txt.value = f"CONNECTING TO {p_data['alias'].upper()}..."
                            progress_bar.visible = True
                            page.update()
                            
                            def s_worker():
                                try:
                                    import requests, uuid
                                    
                                    files_to_send = []
                                    for p in list(state["selected_items"]):
                                        if os.path.isdir(p):
                                            for root, _, files in os.walk(p):
                                                for f in files:
                                                    if f.lower().endswith(('.cbz', '.cbr', '.pdf', '.epub')):
                                                        files_to_send.append(os.path.join(root, f))
                                        elif os.path.isfile(p):
                                            files_to_send.append(p)
                                            
                                    total_send = len(files_to_send)
                                    if total_send == 0:
                                        status_txt.value = "NO VALID FILES TO SEND."
                                        progress_bar.visible = False
                                        page.update()
                                        return
                                        
                                    s_count = 0
                                    for idx, s_path in enumerate(files_to_send):
                                        s_name = os.path.basename(s_path)
                                        status_txt.value = f"[{idx+1}/{total_send}] SENDING {s_name.upper()}..."
                                        progress_bar.value = (idx+1)/total_send
                                        page.update()
                                        
                                        upload_url = f"http://{p_data['ip']}:{p_data['port']}/upload/{uuid.uuid4().hex}"
                                        headers = {'X-File-Name': s_name}
                                        
                                        with open(s_path, 'rb') as vf:
                                            resp = requests.post(upload_url, data=vf, headers=headers)
                                            if resp.status_code == 200:
                                                s_count += 1
                                                
                                    status_txt.value = f"TRANSMISSION COMPLETE: {s_count}/{total_send} DELIVERED."
                                    progress_bar.value = 1.0
                                    page.update()
                                    time.sleep(3)
                                    status_txt.value = "STANDING BY"
                                    progress_bar.visible = False
                                    page.update()
                                except Exception as err:
                                    status_txt.value = f"TRANSFER ERROR: {str(err).upper()}"
                                    page.update()
                                    
                            import threading
                            threading.Thread(target=s_worker, daemon=True).start()
                            
                        peers_controls.append(eink_button(f"SEND TO {peer_data['alias'].upper()}", on_click=send_to_peer, expand=True, is_primary=True))
                
                peers_col = ft.Column(peers_controls) if peers_controls else ft.Container()

                def run_convert(e):
                    if not state["selected_items"]: return
                    
                    status_txt.value = "GATHERING FILES..."
                    progress_bar.visible = True
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
                                            if f.lower().endswith(('.cbz', '.cbr')):
                                                files_to_process.append(os.path.join(root, f))
                                elif os.path.isfile(p) and p.lower().endswith(('.cbz', '.cbr')):
                                    files_to_process.append(p)
                                    
                            total_files = len(files_to_process)
                            if total_files == 0:
                                status_txt.value = "NO VALID COMICS FOUND IN SELECTION."
                                progress_bar.visible = False
                                page.update()
                                return
                                
                            base_dir = os.path.dirname(os.path.abspath(__file__))
                            downloads_dir = os.path.join(base_dir, "webapp", "downloads")
                            os.makedirs(downloads_dir, exist_ok=True)
                            
                            success_count = 0
                            for idx, src in enumerate(files_to_process):
                                # Update global status text to show overall batch progress
                                src_filename = os.path.basename(src)
                                status_txt.value = f"[{idx+1}/{total_files}] PREPPING {src_filename.upper()}..."
                                page.update()
                                
                                out_ext = f".{state['output_format']}"
                                out_filename = src_filename.replace(".cbz", out_ext).replace(".cbr", out_ext).replace(".CBZ", out_ext).replace(".CBR", out_ext)
                                dst = os.path.join(downloads_dir, out_filename)
                                
                                # Callback wrapper to prepend batch status
                                def batch_progress(p, msg):
                                    progress_bar.value = p/100
                                    status_txt.value = f"[{idx+1}/{total_files}] {int(p)}% | {msg.upper()}"
                                    page.update()
                                
                                try:
                                    res = False
                                    if state["output_format"] == "pdf":
                                        res = cbz_to_pdf_engine(src, dst, progress_callback=batch_progress, compress=state["compress_enabled"], max_size_mb=None)
                                    elif state["output_format"] == "epub":
                                        res = cbz_to_epub_engine(src, dst, manga_mode=state["manga_mode"], optimize=state["compress_enabled"], progress_callback=batch_progress)
                                    
                                    if res: success_count += 1
                                except Exception as inner_e:
                                    print(f"Skipping {src} due to error: {inner_e}")
                            
                            status_txt.value = f"BATCH COMPLETE: {success_count}/{total_files} READY FOR WI-FI."
                            progress_bar.value = 1.0
                            
                            # Clear selection after successful batch processing
                            state["selected_items"].clear()
                            
                            page.update()
                            time.sleep(2)
                            render_ui() # Refresh the UI to reflect cleared checkboxes
                            
                        except Exception as err:
                            status_txt.value = f"BATCH ERROR: {str(err).upper()}"
                            page.update()
                            
                    import threading
                    threading.Thread(target=worker).start()

                def run_import(e):
                    if not state["selected_items"]: return
                    
                    status_txt.value = "IMPORTING FILES..."
                    progress_bar.visible = True
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
                                            if f.lower().endswith(('.cbz', '.cbr')):
                                                files_to_process.append(os.path.join(root, f))
                                elif os.path.isfile(p) and p.lower().endswith(('.cbz', '.cbr')):
                                    files_to_process.append(p)
                                    
                            total_files = len(files_to_process)
                            if total_files == 0:
                                status_txt.value = "NO VALID COMICS FOUND IN SELECTION."
                                progress_bar.visible = False
                                page.update()
                                return
                                
                            success_count = 0
                            new_selected = set()
                            for idx, src in enumerate(files_to_process):
                                src_filename = os.path.basename(src)
                                status_txt.value = f"[{idx+1}/{total_files}] IMPORTING {src_filename.upper()}..."
                                progress_bar.value = (idx+1)/total_files
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
                                                    status_txt.value = f"[{idx+1}/{total_files}] COPYING {src_filename.upper()}... {mb_copied:.1f}MB / {mb_total:.1f}MB ({int(perc*100)}%)"
                                                    progress_bar.value = perc
                                                    page.update()
                                                    
                                    success_count += 1
                                except Exception as inner_e:
                                    print(f"Skipping {src} setup due to error: {inner_e}")
                            
                            status_txt.value = f"IMPORT COMPLETE: {success_count}/{total_files} READY IN INTERNAL LIBRARY."
                            progress_bar.value = 1.0
                            
                            state["view_mode"] = "internal"
                            state["current_path"] = comic_library_dir
                            state["selected_items"] = new_selected
                            
                            page.update()
                            time.sleep(2)
                            render_ui()
                            
                        except Exception as err:
                            status_txt.value = f"IMPORT ERROR: {str(err).upper()}"
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
                                        if f.lower().endswith(('.cbz', '.cbr')):
                                            count += 1
                            except: pass
                        elif os.path.isfile(p) and p.lower().endswith(('.cbz', '.cbr')):
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
                    if state["view_mode"] == "external" and start_path == "/storage":
                        for drive in get_android_drives():
                             if isinstance(file_list, ft.Column): file_list.controls.append(list_item(drive, "💾", drive, is_dir=True))
                    else:
                        if state["view_mode"] == "external":
                            parent = os.path.dirname(start_path)
                            if isinstance(file_list, ft.Column):
                                file_list.controls.append(
                                    ft.Row([
                                        ft.Container(content=ft.Text("UP DIR", color="white", weight="w900"), on_click=lambda _: navigate(parent), bgcolor="black", padding=15, expand=True, ink=True),
                                        ft.Container(content=ft.Text("DRIVES", color="black", weight="w900"), on_click=lambda _: navigate("/storage"), bgcolor="white", border=ft.border.all(2,"black"), padding=15, ink=True),
                                    ])
                                )
                        else:
                            if start_path != comic_library_dir:
                                parent = os.path.dirname(start_path)
                                if isinstance(file_list, ft.Column):
                                    file_list.controls.append(
                                        ft.Container(content=ft.Text("UP DIR", color="white", weight="w900"), on_click=lambda _: navigate(parent), bgcolor="black", padding=15, expand=True, ink=True)
                                    )
                        
                        items = sorted(os.listdir(start_path))
                        for item in items:
                            full_path = os.path.join(start_path, item)
                            if os.path.isdir(full_path):
                                file_list.controls.append(list_item(item, "📂", full_path, is_dir=True))
                            else:
                                if item.lower().endswith(('.cbz', '.cbr')):
                                    file_list.controls.append(list_item(item, "📄", full_path, is_file=True))
                                else:
                                    if isinstance(file_list, ft.Column):
                                        file_list.controls.append(
                                            ft.Container(
                                                content=ft.Row([
                                                    ft.Text("⚠️", size=24),
                                                    ft.Text(item, size=16, color="grey", no_wrap=True)
                                                ]),
                                                bgcolor="#EEEEEE",
                                                border=ft.border.all(1, "grey"),
                                                padding=15
                                            )
                                        )
                except Exception as e:
                    file_list.controls.append(ft.Text(f"ACCESS DENIED: {e}", color="black", weight="w900"))

                # Final Layout construction
                page.add(
                    ft.Container(
                        content=ft.Column([
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
                            peers_col,
                            progress_bar,
                            status_txt
                        ], spacing=10),
                        padding=15,
                        border=ft.border.all(4, "black")
                    )
                )
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
