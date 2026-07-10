const fs = require('fs');
const content = fs.readFileSync(String.raw`C:\Users\chris\.gemini\antigravity-ide\brain\5c56199b-bc4b-4938-8a9f-9022011d421f\.system_generated\steps\140\content.md`, 'utf8');
const jsonStr = content.split('---')[1].trim();
const data = JSON.parse(jsonStr);
fs.writeFileSync('crash_body.txt', data[0].body);
