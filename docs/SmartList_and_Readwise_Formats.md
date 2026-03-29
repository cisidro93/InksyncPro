# List & Sync Structuring Guide

This document defines the natively supported file structures for **Smart Lists** (Issue/Chapter bulk importing) and **Readwise Highlight Imports**, ensuring that external AIs or manual data entry will be parsed seamlessly by InksyncPro without troubleshooting.

## 1. Smart List Imports (`.csv`, `.txt`, `.md`)

The importer utilizes a robust Context Engine to identify chapters, issues, and series metadata. You can use standard tabular CSV data or lightweight Markdown/Text.

### Form 1: Standard CSV Table
If using a `.csv` file, the engine looks for standard column headers. **It natively supports the `Volume,Start_Chapter,End_Chapter` format** found in your reference files.

**Supported Headers (Case-Insensitive):**
- **Series / Title / Book:** The name of the comic (e.g. `Initial D`)
- **Issue / Number / #:** Specific issue or chapter (e.g. `12`)
- **Start_Chapter / Start:** Beginning of a chunk (e.g. `1`)
- **End_Chapter / End:** End of a chunk (e.g. `7`)
- **Volume / Vol:** Volume context (e.g. `1`)

**Example `initial_d_chapter_breakdown.csv` Output:**
```csv
Volume,Start_Chapter,End_Chapter
1,1,7
2,8,14
3,15,21
```
*(Note: If the `Series/Title` column is omitted, the engine will automatically fall back to using the filename of the CSV as the Series name—so naming the file `Initial D.csv` assigns all those chunks to Initial D!)*

### Form 2: Contextual Markdown
If you are generating lists with an AI, you can just use simple text files using Markdown headers to create a context hierarchy.

**Example Text List:**
```markdown
# Initial D
## Volume 1
Ch 1-7
## Volume 2
Ch 8-14
```
*(The engine will automatically expand `Ch 1-7` into 7 separate issue requests assigned to Volume 1 of Initial D).*

---

## 2. Readwise Highlights Import (`.csv`)

InksyncPro's native `ReadwiseImportService` is already mapped to support standard Readwise `.csv` exports out-of-the-box. 

**Required Columns:**
The CSV *must* contain these two columns (headers are case-insensitive):
- `Highlight` (or `Text`, `Highlights`)
- `Title` (or `Book Title`)

**Optional Supported Columns:**
- `Note` (or `Notes`) - Injected directly as your personal Zettelkasten note on the highlight.
- `Author` (or `Book Author`)

**Example Supported Format:**
```csv
Highlight,Book Title,Book Author,Note
"The Definition of Hell is being on your deathbed and meeting the man you could have become.",The Pursuit of Legendary Fatherhood,Larry Hagner,Great motivational quote!
"Things changed, and they didn’t change back. But sometimes they got better.",Nemesis Games,James S. A. Corey,
```
*(Any other columns like `Tags`, `Location`, or `Amazon Book ID` are safely ignored by the parser without breaking the import).*
