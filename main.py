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
            "view_mode": "external" # 'external' for Import, 'internal' for Convert
        }
        
        # Initialize internal storage directory
        base_dir = os.path.dirname(os.path.abspath(__file__))
        comic_library_dir = os.path.join(base_dir, "comic_library")
        os.makedirs(comic_library_dir, exist_ok=True)
        downloads_dir = os.path.join(base_dir, "webapp", "downloads")
        os.makedirs(downloads_dir, exist_ok=True)
        
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
                        ink=True
                    )
                ], spacing=0)

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
                            try:
                                import sys, os
                                webapp_path = os.path.join(os.path.dirname(__file__), "webapp")
                                if webapp_path not in sys.path: sys.path.append(webapp_path)
                                from app import app as flask_app
                                from werkzeug.serving import make_server
                                web_server = make_server('0.0.0.0', 5000, flask_app)
                                state["server_running"] = True
                                ip = get_local_ip()
                                server_url_txt.value = f"SERVER ACTIVE AT:\nhttp://{ip}:5000"
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
                            for idx, src in enumerate(files_to_process):
                                src_filename = os.path.basename(src)
                                status_txt.value = f"[{idx+1}/{total_files}] IMPORTING {src_filename.upper()}..."
                                progress_bar.value = (idx+1)/total_files
                                page.update()
                                
                                dst = os.path.join(comic_library_dir, src_filename)
                                try:
                                    if not os.path.exists(dst):
                                        shutil.copy2(src, dst)
                                    success_count += 1
                                except Exception as inner_e:
                                    print(f"Skipping {src} setup due to error: {inner_e}")
                            
                            status_txt.value = f"IMPORT COMPLETE: {success_count}/{total_files} READY IN INTERNAL LIBRARY."
                            progress_bar.value = 1.0
                            
                            state["selected_items"].clear()
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
                    convert_btn_text = f"{verb} {total_comics} COMIC(S)"
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
                    
                    def on_check(e):
                        toggle_selection(full_path, e.control.value)
                        
                    def on_row_click(e):
                        if is_dir: navigate(full_path)
                        elif is_file: toggle_selection(full_path, not is_selected)
                        
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
                
                file_list = ft.Column(scroll="auto", expand=True, spacing=2)
                start_path = state["current_path"]
                
                try:
                    if state["view_mode"] == "external":
                        if start_path == "/storage":
                            for drive in get_android_drives():
                                 file_list.controls.append(list_item(drive, "💾", drive, is_dir=True))
                        else:
                            parent = os.path.dirname(start_path)
                            file_list.controls.append(
                                ft.Row([
                                    ft.Container(content=ft.Text("UP DIR", color="white", weight="w900"), on_click=lambda _: navigate(parent), bgcolor="black", padding=15, expand=True, ink=True),
                                    ft.Container(content=ft.Text("DRIVES", color="black", weight="w900"), on_click=lambda _: navigate("/storage"), bgcolor="white", border=ft.border.all(2,"black"), padding=15, ink=True),
                                ])
                            )
                    else:
                        if start_path != comic_library_dir:
                            parent = os.path.dirname(start_path)
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
                            ft.Text(start_path, color="black", size=14, weight="bold"),
                            ft.Container(content=file_list, height=400),
                            
                            ft.Container(bgcolor="black", height=4),
                            ft.Row([btn_server, btn_convert]),
                            server_url_txt,
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
