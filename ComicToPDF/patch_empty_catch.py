import os
import re

pattern = re.compile(r'catch\s*\{\s*\}')
replacement = r'catch { Logger.shared.log("Silenced empty catch: \(error.localizedDescription)", category: "System", level: .error) }'

count = 0
for root, dirs, files in os.walk('ComicToPDF/ComicToPDF'):
    for file in files:
        if file.endswith('.swift'):
            path = os.path.join(root, file)
            with open(path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            new_content = pattern.sub(replacement, content)
            
            if new_content != content:
                with open(path, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                print(f"Patched: {path}")
                count += 1

print(f"Total files patched: {count}")
