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
            "selected_file": "/storage/emulated/0/Download",
            "output_format": "epub", # default to epub for kindle
            "compress_enabled": False,
            "manga_mode": False,
            "server_running": False
        }
        
        # Initialize engines
        import cbz_to_pdf
        import cbz_to_epub
        global cbz_to_pdf_engine
        global cbz_to_epub_engine
        cbz_to_pdf_engine = cbz_to_pdf.convert_cbz_to_pdf
        cbz_to_epub_engine = cbz_to_epub.convert_cbz_to_epub

        # --- MAIN CONVERTER SCREEN (E-INK STYLED) ---
        def show_main_ui():
            try:
                page.clean()
                
                def eink_button(text, on_click, expand=False, is_primary=False):
                    return ft.Container(
                        content=ft.Text(text, size=20, weight="w900", color="white" if is_primary else "black", text_align="center"),
                        on_click=on_click,
                        bgcolor="black" if is_primary else "white",
                        border=ft.border.all(3, "black"),
                        padding=20,
                        border_radius=0, 
                        ink=True,
                        expand=expand
                    )

                path_input = ft.TextField(
                    label="Selected File", 
                    value=state["selected_file"], 
                    expand=True,
                    read_only=True,
                    border_color="black",
                    border_width=2,
                    text_size=18
                )
                
                def select_format(e):
                    val = e.control.value
                    state["output_format"] = val
                    sw_manga.visible = (val == "epub")
                    page.update()

                format_radios = ft.RadioGroup(
                    content=ft.Row([
                        ft.Radio(value="epub", label="EPUB (Kindle)"),
                        ft.Radio(value="pdf", label="PDF (Universal)")
                    ]),
                    value=state["output_format"],
                    on_change=select_format
                )

                sw_optimize = ft.Switch(
                    label="Optimize for E-ink (Save Space, Keep Color)", 
                    value=state["compress_enabled"], 
                    on_change=lambda e: state.update({"compress_enabled": e.control.value}),
                    visible=True, 
                    active_color="black"
                )
                
                sw_manga = ft.Switch(
                    label="Manga Mode (Right-to-Left) [EPUB Only]", 
                    value=state["manga_mode"],
                    on_change=lambda e: state.update({"manga_mode": e.control.value}),
                    visible=(state["output_format"] == "epub"),
                    active_color="black"
                )
                
                progress_bar = ft.ProgressBar(width=300, visible=False, color="black", bgcolor="white")
                status_txt = ft.Text("STANDING BY", color="black", weight="w900", size=24)
                
                def on_browse_click(e):
                    show_browser_ui(state["current_path"])

                def get_local_ip():
                    import socket
                    try:
                        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        s.connect(("8.8.8.8", 80))
                        ip = s.getsockname()[0]
                        s.close()
                        return ip
                    except: return "127.0.0.1"

                server_url_txt = ft.Text("", color="black", weight="w900", size=16, text_align="center")
                
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
                                if webapp_path not in sys.path:
                                    sys.path.append(webapp_path)
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
                            global web_server
                            web_server.shutdown()
                            state["server_running"] = False
                            server_url_txt.value = ""
                            btn_server.content.value = "START WI-FI SERVER"
                            status_txt.value = "SERVER STOPPED"
                            page.update()
                        except Exception as err:
                            status_txt.value = f"STOP ERROR: {err}"
                            page.update()
                            
                btn_server = eink_button("START WI-FI SERVER", on_click=toggle_server, expand=True)

                def on_progress(p, msg):
                    progress_bar.value = p/100
                    status_txt.value = f"{int(p)}% | {msg.upper()}"
                    page.update()
                    
                def run_convert(e):
                    src = path_input.value
                    if not src or "Download" in src and src == state["current_path"]:
                        status_txt.value = "ERROR: SELECT A FILE"
                        page.update()
                        return
                    
                    state["selected_file"] = src 
                    
                    base_dir = os.path.dirname(os.path.abspath(__file__))
                    downloads_dir = os.path.join(base_dir, "webapp", "downloads")
                    os.makedirs(downloads_dir, exist_ok=True)
                    
                    src_filename = os.path.basename(src)
                    out_ext = f".{state['output_format']}"
                    out_filename = src_filename.replace(".cbz", out_ext).replace(".cbr", out_ext)
                    dst = os.path.join(downloads_dir, out_filename)
                    
                    status_txt.value = "INITIALIZING..."
                    progress_bar.visible = True
                    page.update()
                    
                    def worker():
                        try:
                            success = False
                            if state["output_format"] == "pdf":
                                success = cbz_to_pdf_engine(
                                    src, 
                                    dst, 
                                    progress_callback=on_progress,
                                    compress=state["compress_enabled"], 
                                    max_size_mb=None
                                )
                            elif state["output_format"] == "epub":
                                success = cbz_to_epub_engine(
                                    src,
                                    dst,
                                    manga_mode=state["manga_mode"],
                                    optimize=state["compress_enabled"], 
                                    progress_callback=on_progress
                                )
                            
                            if success is False:
                                 raise Exception("Engine returned False")

                            status_txt.value = "JOB COMPLETE (READY FOR WI-FI SYNC)"
                            page.update()

                        except Exception as err:
                            status_txt.value = f"ERROR: {str(err).upper()}"
                            page.update()
                    
                    threading.Thread(target=worker).start()
                    
                page.add(
                    ft.Container(
                        content=ft.Column([
                            ft.Text("COMIC SYNC PRO", size=36, weight="w900", color="black"),
                            ft.Container(bgcolor="black", height=4),
                            
                            ft.Row([
                                path_input,
                                eink_button("BROWSE", on_click=on_browse_click)
                            ]),
                            
                            ft.Container(bgcolor="black", height=2),
                            ft.Text("OUTPUT FORMAT", size=18, weight="w900"),
                            format_radios,
                            sw_optimize,
                            sw_manga,
                            
                            ft.Container(bgcolor="black", height=2),
                            eink_button("CONVERT FILE", on_click=run_convert, expand=True, is_primary=True),
                            
                            ft.Container(height=10),
                            btn_server,
                            server_url_txt,
                            
                            ft.Container(height=20),
                            progress_bar,
                            status_txt
                        ], spacing=15),
                        padding=20,
                        border=ft.border.all(4, "black")
                    )
                )
                page.update()
                
            except Exception as e:
                # Local UI error capture
                raise e

        # --- FULL PAGE FILE BROWSER (E-INK STYLED) ---
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

        def show_browser_ui(start_path):
            page.clean()
            state["current_path"] = start_path
            
            file_list = ft.Column(scroll="auto", expand=True, spacing=2)
            path_display = ft.Text(start_path, color="black", size=16, weight="bold")
            
            def navigate(path): show_browser_ui(path)
            def select(path):
                state["selected_file"] = path
                state["current_path"] = os.path.dirname(path)
                show_main_ui()
                
            def list_item(text, icon, on_click, is_dir=False, is_file=False):
                return ft.Container(
                    content=ft.Row([
                        ft.Text(icon, size=24),
                        ft.Text(text, size=20, weight="w900" if is_dir else "w700", color="white" if is_file else "black", no_wrap=True)
                    ]),
                    on_click=on_click,
                    bgcolor="black" if is_file else "white",
                    border=ft.border.all(2, "black"),
                    padding=15,
                    ink=True
                )

            try:
                if start_path == "/storage":
                    file_list.controls.append(ft.Text("DRIVES", weight="w900", size=24))
                    for drive in get_android_drives():
                         file_list.controls.append(list_item(drive, "💾", lambda _, p=drive: navigate(p), is_dir=True))
                else:
                    parent = os.path.dirname(start_path)
                    file_list.controls.append(
                        ft.Row([
                            ft.Container(content=ft.Text("UP DIR", color="white", weight="w900"), on_click=lambda _: navigate(parent), bgcolor="black", padding=15, expand=True, ink=True),
                            ft.Container(content=ft.Text("DRIVES", color="black", weight="w900"), on_click=lambda _: navigate("/storage"), bgcolor="white", border=ft.border.all(2,"black"), padding=15, ink=True),
                        ])
                    )
                    
                    items = sorted(os.listdir(start_path))
                    for item in items:
                        full_path = os.path.join(start_path, item)
                        if os.path.isdir(full_path):
                            file_list.controls.append(list_item(item, "📂", lambda _, p=full_path: navigate(p), is_dir=True))
                        elif item.lower().endswith(('.cbz', '.cbr')):
                            file_list.controls.append(list_item(item, "📄", lambda _, p=full_path: select(p), is_file=True))
                            
            except Exception as e:
                file_list.controls.append(ft.Text(f"ACCESS DENIED: {e}", color="black", weight="w900"))

            page.add(
                ft.Container(
                    content=ft.Column([
                        ft.Text("SELECT FILE", size=32, weight="w900"),
                        path_display,
                        ft.Container(bgcolor="black", height=4),
                        ft.Container(content=file_list, height=500),
                        ft.Container(bgcolor="black", height=4),
                        ft.Container(
                            content=ft.Text("CANCEL", size=20, weight="w900", text_align="center"),
                            on_click=lambda _: show_main_ui(),
                            border=ft.border.all(3, "black"),
                            padding=15,
                            ink=True
                        )
                    ]),
                    padding=20,
                    border=ft.border.all(4, "black")
                )
            )
            page.update()

        # Start the fast UI synchronously
        show_main_ui()

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
