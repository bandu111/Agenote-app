# Agenote first-run local typography

- Instrument Sans: Google Fonts, SIL Open Font License (OFL-InstrumentSans.txt).
  Source: https://github.com/google/fonts/tree/main/ofl/instrumentsans
- NotoSansSC-Regular.ttf: existing project font and existing OFL-NotoSansSC.txt.
- NotoSansSC-Medium-FirstRun.ttf: weight 500, text subset of Google Fonts
  Noto Sans SC variable font, generated with fontTools for the static first-run
  and authentication copy. Other characters fall back to the existing full regular font.
  Source: https://github.com/google/fonts/tree/main/ofl/notosanssc

All runtime loading uses Flutter bundled fonts; no online font requests.
