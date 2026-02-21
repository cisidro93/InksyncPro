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
        "manga_mode": False
    }
    
    # 1. Boot Message (E-ink stark contrast)
    boot_text = ft.Text("SYSTEM STARTUP", color="black", size=24, weight="w900")
    log_column = ft.Column(scroll="auto", expand=True)
    page.add(
        ft.Container(
            content=ft.Column([boot_text, log_column]),
            padding=20,
            border=ft.border.all(4, "black"),
            bgcolor="white"
        )
    )

    def log(msg, is_error=False):
        print(msg)
        color = "black" if not is_error else "red"
        # Always use bold/heavy fonts for e-ink readability
        log_column.controls.append(ft.Text(f"> {msg}", color=color, size=18, weight="bold"))
        page.update()

    log(f"Python Runtime: {sys.version}")
    log("Initializing Enterprise E-ink Interface...")
    
    def load_engines():
        global cbz_to_pdf_engine
        global cbz_to_epub_engine
        try:
            log("Loading PDF Engine...")
            import cbz_to_pdf
            if hasattr(cbz_to_pdf, 'convert_cbz_to_pdf'):
                cbz_to_pdf_engine = cbz_to_pdf.convert_cbz_to_pdf
            
            log("Loading EPUB Engine...")
            import cbz_to_epub
            if hasattr(cbz_to_epub, 'convert_cbz_to_epub'):
                cbz_to_epub_engine = cbz_to_epub.convert_cbz_to_epub
                
            if cbz_to_epub_engine and cbz_to_pdf_engine:
                log("Engines OK. Launching UI...")
                show_main_ui()
            else:
                log("FATAL: Engine bindings missing.", is_error=True)
                
        except Exception as e:
            log(f"IMPORT FAILURE: {e}\n{traceback.format_exc()}", is_error=True)

    # --- MAIN CONVERTER SCREEN (E-INK STYLED) ---
    def show_main_ui():
        try:
            page.clean()
            
            # Helper to create highly visible e-ink buttons
            def eink_button(text, on_click, expand=False, is_primary=False):
                return ft.Container(
                    content=ft.Text(text, size=20, weight="w900", color="white" if is_primary else "black", text_align="center"),
                    on_click=on_click,
                    bgcolor="black" if is_primary else "white",
                    border=ft.border.all(3, "black"),
                    padding=20,
                    border_radius=0, # Sharp corners for e-ink clarity
                    ink=True,
                    expand=expand,
                    alignment=ft.alignment.center
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
            
            # Toggle format
            def select_format(e):
                val = e.control.value
                state["output_format"] = val
                # Update visibility of specific settings
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

            # Feature Controls
            sw_optimize = ft.Switch(
                label="Optimize for E-ink (Save Space, Keep Color)", 
                value=state["compress_enabled"], # Repurposing this state key for general optimization
                on_change=lambda e: state.update({"compress_enabled": e.control.value}),
                visible=True, # Visible for both formats now
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
                
                # Setup Output Path (Route directly to webapp/downloads to enable immediate Wi-Fi Sync)
                base_dir = os.path.dirname(os.path.abspath(__file__))
                downloads_dir = os.path.join(base_dir, "webapp", "downloads")
                os.makedirs(downloads_dir, exist_ok=True)
                
                # Create output filename based on source format
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
                                compress=state["compress_enabled"], # Now effectively means 'optimize'
                                max_size_mb=None # No strict limit, rely on optimization resizing
                            )
                        elif state["output_format"] == "epub":
                            success = cbz_to_epub_engine(
                                src,
                                dst,
                                manga_mode=state["manga_mode"],
                                optimize=state["compress_enabled"], # We need to update cbz_to_epub signature to accept this
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
                
            # Layout
            page.add(
                ft.Container(
                    content=ft.Column([
                        ft.Text("COMIC SYNC PRO", size=36, weight="w900", color="black"),
                        ft.Container(bgcolor="black", height=4), # Thick separator
                        
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
                        eink_button("CONVERT TO WI-FI SERVER", on_click=run_convert, expand=True, is_primary=True),
                        
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
            log(f"UI ERROR: {e}", is_error=True)

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
            
        # Helper for massive e-ink list items
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
                    elif item.lower().endswith('.cbz'):
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

    # Boot Sequence (Run synchronously to avoid Android Flet threading issues with page.update)
    load_engines()

if __name__ == "__main__":
    ft.app(target=main)
