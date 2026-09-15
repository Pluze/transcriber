## Install on macOS

### v1.3.0

- Adds optional speaker labeling with automatic speaker-count detection or an
  exact count from 2 through 30; the default remains off for compatibility.
- Keeps the original Whisper transcript files unchanged and writes separate
  speaker-labeled TXT, SRT, JSON, timeline, and diagnostic outputs.
- Bundles the FluidAudio speaker diarization models in the app, so speaker
  labeling works offline without a first-run model download.
- Adds the speaker model pack to the Models panel with its bundled size,
  source, and CC BY 4.0 attribution.
- Sets the minimum supported system to macOS 14.

### v1.2.3

- Makes Compact the default model for fast everyday transcription, small
  downloads, and low storage use.
- Keeps Maximum Fidelity as the accuracy-first choice on capable Macs while
  making its processing-time tradeoff explicit.
- Clarifies that Balanced and Compact offer substantial speed advantages and
  strong speed-to-quality value.
- Preserves the stable decoding policy used by v1.2.2 across every model and
  benchmark run.

### v1.2.2

- Runs two Compact files concurrently on the reference M5 when live GPU,
  memory, CPU, power, and thermal checks permit it; higher-core Macs may use
  three workers.
- Separates Active and Queue progress. Each has its own rolling ETA, while total
  queue progress is duration-weighted and monotonic across parallel work.
- Produces a same-named ZIP next to every transcript result folder.
- Preserves the fixed beam/context decoding policy across all concurrency
  choices, so scheduling changes throughput rather than recognition settings.
- Rechecks pending queues every two seconds, preventing a long active recording
  from blocking short queued files after a temporary concurrency reduction.

### v1.2.1

- Shows live inference percentage so long recordings no longer appear stuck at
  “running bundled large-v3”.
- Keeps verbose engine output out of the main UI, preserving the low GUI CPU
  usage introduced in v1.2.0.
- Cleans up per-job progress state on cancellation or launch failure.
- Displays the installed release version and build number in the main window.

Download the App ZIP, unzip it, and drag `Transcriber.app` to Applications.

This unsigned community build may be blocked the first time it is opened. Control-click the app, choose **Open**, then choose **Open** again. This one-time confirmation is macOS's supported way to open an app from an unidentified developer.
