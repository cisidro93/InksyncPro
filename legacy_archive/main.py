import flet as ft
import sys
import os
import traceback
import time
import threading
import shutil

# --- GLOBALS ---
conversion_engine = None
default_path = os.path.dirname(os.path.abspath(__file__))

def main(page):
    # --- 1. BOOT UI ---
    page.title = "CBZ Converter (Build #89)"
    page.scroll = "auto"
    page.theme_mode = ft.ThemeMode.LIGHT
    page.padding = 20
    
    page.add(ft.Text("System Boot: Build #90 (Granular Trace)", color="blue", size=16, weight="bold"))
    
    # --- 2. DEFINE HELPERS (Must be first) ---
    def log(msg, color="black"):
        print(msg)
        try:
            page.add(ft.Text(str(msg), color=color, size=12))
            page.update()
        except:
            pass

    log("Trace: Helpers Defined")

    # --- 3. DEFINE STATE ---
    state = {
        "current_path": default_path,
        "selected_file": "Select a file...",
        "compress_enabled": False,
        "email_sender": "",
        "email_password": "",
        "email_recipient": ""
    }
    log("Trace: State Defined")

    # --- 4. DEFINE HANDLERS (Must be defined before Buttons use them) ---
    
    # HANDLER: Load Engine
    def load_engine_click(e):
        global conversion_engine
        
        try:
            btn_load.disabled = True
            btn_load.text = "Loading Engine..."
            page.update()
            
            log("Importing CBZ Engine...")
            import cbz_to_pdf
            
            if hasattr(cbz_to_pdf, 'convert_cbz_to_pdf'):
                conversion_engine = cbz_to_pdf.convert_cbz_to_pdf
                log("Engine Loaded!", "green")
                show_main_ui()
            else:
                log("Error: convert func missing", "red")
                btn_load.disabled = False
                page.update()
                
        except Exception as ex:
            log(f"Load Error: {ex}", "red")
            btn_load.disabled = False
            page.update()

    log("Trace: Load Handler Defined")
    # HANDLER: Settings
    def show_settings_ui():
        page.clean()
        txt_sender = ft.TextField(label="Gmail", value=state["email_sender"])
        txt_pass = ft.TextField(label="App Password", value=state["email_password"], password=True)
        txt_kindle = ft.TextField(label="Kindle Email", value=state["email_recipient"])
        
        def save(e):
            state["email_sender"] = txt_sender.value
            state["email_password"] = txt_pass.value
            state["email_recipient"] = txt_kindle.value
            show_main_ui()
            
        page.add(
            ft.Text("Settings", size=24),
            txt_sender, txt_pass, txt_kindle,
            ft.ElevatedButton("Save", on_click=save)
        )
        page.update()

    log("Trace: Settings Handler Defined")
    # HANDLER: Browser
    def show_browser_ui(start_path):
        page.clean()
        if not os.path.exists(start_path):
             start_path = os.path.expanduser("~")
             
        state["current_path"] = start_path
        
        def nav(p): show_browser_ui(p)
        def sel(p): 
            state["selected_file"] = p
            state["current_path"] = os.path.dirname(p)
            show_main_ui()
            
        controls = []
        controls.append(ft.Text(start_path, color="grey"))
        
        # Inbox Check
        inbox = os.path.join(os.path.expanduser("~"), "Documents", "Inbox")
        if os.path.exists(inbox):
             controls.append(ft.ElevatedButton("Check Inbox", on_click=lambda _: nav(inbox), bgcolor="purple", color="white"))
             
        # UP Button
        parent = os.path.dirname(start_path)
        if start_path != os.path.expanduser("~"):
             controls.append(ft.ElevatedButton(".. (UP)", on_click=lambda _: nav(parent)))
             
        try:
            items = sorted(os.listdir(start_path))
            for item in items:
                full = os.path.join(start_path, item)
                if os.path.isdir(full):
                    controls.append(ft.OutlinedButton(f"Dir: {item}", on_click=lambda _, p=full: nav(p)))
                elif item.endswith(".cbz"):
                    controls.append(ft.ElevatedButton(f"File: {item}", on_click=lambda _, p=full: sel(p), bgcolor="blue", color="white"))
                else:
                    controls.append(ft.Text(item))
        except Exception as e:
            controls.append(ft.Text(f"Error: {e}", color="red"))
            
        page.add(ft.Column(controls, scroll="always"))
        page.update()

    log("Trace: Browser Handler Defined")
    # HANDLER: Main UI
    def show_main_ui():
        log("Building Main UI...")
        page.clean()
        
        txt_path = ft.TextField(label="Path", value=state["selected_file"])
        
        def on_convert(e):
            src = txt_path.value
            if not os.path.exists(src):
                log("File not found!", "red")
                return
            
            log("Starting conversion...")
            # Threaded conversion
            def worker():
                try:
                    dst = src.replace(".cbz", ".pdf")
                    log("Converting...")
                    success = conversion_engine(src, dst, progress_callback=lambda p,m: None, compress=state["compress_enabled"], max_size_mb=50)
                    if success:
                        log("Done!", "green")
                        if state["email_sender"]:
                             log("Emailing...")
                             import email_sender
                             email_sender.send_email(dst, state["email_sender"], state["email_password"], state["email_recipient"])
                             log("Email Sent!")
                    else:
                        log("Conversion Failed", "red")
                except Exception as ex:
                    log(f"Error: {ex}", "red")
            
            threading.Thread(target=worker).start()
            
        page.add(
            ft.Text("CBZ Converter", size=24, weight="bold"),
            ft.ElevatedButton("Settings", on_click=lambda _: show_settings_ui()),
            txt_path,
            ft.Switch(label="Compress", value=state["compress_enabled"], on_change=lambda e: state.update({"compress_enabled": e.control.value})),
            ft.ElevatedButton("Convert", on_click=on_convert, bgcolor="green", color="white"),
            ft.ElevatedButton("Browse", on_click=lambda _: show_browser_ui(state["current_path"])),
            ft.Text("Logs:")
        )
        page.update()

    log("Trace: Main UI Handler Defined")

    # HANDLER: Drop
    def on_file_drop(e):
        if e.files:
            f = e.files[0]
            log(f"Dropped: {f.name}")
            state["selected_file"] = f.path
            show_main_ui()

    page.on_file_drop = on_file_drop
    log("Trace: Handlers Defined")

    # --- 5. INITIAL UI (Buttons) ---
    btn_load = ft.ElevatedButton("LOAD ENGINE", on_click=load_engine_click, bgcolor="blue", color="white")
    page.add(ft.Divider(), btn_load)
    page.update()
    
    log("Trace: Initial UI Built")

    # --- 6. BACKGROUND TASKS ---
    def background_init():
        log("Background Init Starting...")
        docs = os.path.join(os.path.expanduser("~"), "Documents")
        if not os.path.exists(docs):
            try:
                os.makedirs(docs)
                log("Created Documents folder")
            except:
                pass
                
        # Inbox Poller
        inbox = os.path.join(docs, "Inbox")
        log(f" watching {inbox}...")
        
        while True:
            try:
                if os.path.exists(inbox):
                    for f in os.listdir(inbox):
                        src = os.path.join(inbox, f)
                        dst = os.path.join(docs, f)
                        if os.path.isfile(src):
                             log(f"Importing {f}...", "green")
                             if os.path.exists(dst):
                                 dst = os.path.join(docs, f"copy_{int(time.time())}.cbz")
                             shutil.move(src, dst)
                             state["selected_file"] = dst
                             # We can't easily refresh UI from thread without page lock, but state is updated.
            except Exception as e:
                pass # Silent poll
            time.sleep(2)

    threading.Thread(target=background_init, daemon=True).start()
    log("Trace: Background Thread Started")
    
    # Debug Info
    log(f"Python: {sys.version}")

if __name__ == "__main__":
    ft.app(target=main)
