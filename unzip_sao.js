const AdmZip = require('adm-zip');
const path = require('path');
const fs = require('fs');

const extractDir = path.join(__dirname, 'wolverine_epub_test');
if (fs.existsSync(extractDir)) {
    fs.rmSync(extractDir, { force: true, recursive: true });
}
fs.mkdirSync(extractDir);

const zip = new AdmZip(path.join('c:/Users/chris/Downloads/Wolverine 003 (2025) (digital) (Marika-Empire).epub'));
zip.extractAllTo(extractDir, true);
console.log('Extracted known working EPUB to wolverine_epub_test.');
