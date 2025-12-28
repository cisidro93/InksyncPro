import plistlib
import sys
import os

def main():
    if len(sys.argv) < 2:
        print("Usage: python inject_plist.py <path_to_info_plist>")
        sys.exit(1)

    plist_path = sys.argv[1]
    print(f"Injecting configuration into: {plist_path}")

    if not os.path.exists(plist_path):
        print(f"Error: File not found at {plist_path}")
        sys.exit(1)

    try:
        with open(plist_path, 'rb') as f:
            pl = plistlib.load(f)
            
        print(f"DEBUG: Initial UIFileSharingEnabled: {pl.get('UIFileSharingEnabled', 'Not Set')}")
        print(f"DEBUG: Initial CFBundleDocumentTypes: {len(pl.get('CFBundleDocumentTypes', []))} items")

        # 1. Enable File Sharing (Folder Visibility)
        print("Enabling UIFileSharingEnabled...")
        pl['UIFileSharingEnabled'] = True
        
        # 1. Enable File Sharing (Folder Visibility)
        print("Enabling UIFileSharingEnabled...")
        pl['UIFileSharingEnabled'] = True
        
        # REMOVE Potential Conflicts
        print("Removing LSSupportsOpeningDocumentsInPlace (Force Default)...")
        if 'LSSupportsOpeningDocumentsInPlace' in pl:
            del pl['LSSupportsOpeningDocumentsInPlace']

        print("Removing UISupportsDocumentBrowser (Force Default)...")
        if 'UISupportsDocumentBrowser' in pl:
            del pl['UISupportsDocumentBrowser']
        
        # 2. Add Document Types (Share Sheet Visibility)
        print("Adding CFBundleDocumentTypes...")
        
        # Define our types
        new_types = [{
            'CFBundleTypeName': 'Comic Book Archive',
            'CFBundleTypeRole': 'Editor',
            'LSHandlerRank': 'Owner',
            'LSItemContentTypes': [
                'com.pkware.zip-archive',
                'public.zip-archive',
                'public.archive', 
                'com.macitbetter.cbz-archive',
                'public.data',
                'application/zip',
                'application/x-cbz'
            ]
        }]
        
        pl['CFBundleDocumentTypes'] = new_types
        
        # Save back
        with open(plist_path, 'wb') as f:
            plistlib.dump(pl, f)
            
        print("Success! Info.plist updated.")
        
    except Exception as e:
        print(f"Error updating plist: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
