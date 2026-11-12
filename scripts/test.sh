#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
swiftc -O -module-cache-path .build/module-cache Sources/WanderRead/{Core,Priority,Insights,ResearchLink,ResearchIntegration,Store,Theme,DataManagement,ObsidianLinks,ShareIdentity,PDFReading,ReadingText,ReadingInspection,RelatedReading,TextReading,ZoteroImport,Glance,FocusLayout,NotebookExport,PDFChapter,PDFScan,PDFOutlineInference,PDFOutlineBuilder,PDFAcademicLayout}.swift Tests/*.swift -o .build/core-tests
.build/core-tests
