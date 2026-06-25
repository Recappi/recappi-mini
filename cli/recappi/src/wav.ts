export interface WavHeaderInfo {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  dataOffset: number;
  dataLength: number;
  durationMs: number;
}

const RIFF_MAGIC = 0x52494646;
const WAVE_MAGIC = 0x57415645;
const FMT_CHUNK_ID = 0x666d7420;
const DATA_CHUNK_ID = 0x64617461;
const PCM_FORMAT = 1;

function readBigEndianUint32(view: DataView, offset: number): number {
  return view.getUint32(offset, false);
}

export function parseWavHeader(buf: ArrayBuffer | Uint8Array): WavHeaderInfo {
  const view =
    buf instanceof Uint8Array
      ? new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
      : new DataView(buf);
  if (view.byteLength < 12) {
    throw new Error("WAV header too small");
  }
  if (readBigEndianUint32(view, 0) !== RIFF_MAGIC) {
    throw new Error("Not a RIFF file");
  }
  if (readBigEndianUint32(view, 8) !== WAVE_MAGIC) {
    throw new Error("Not a WAVE file");
  }

  let cursor = 12;
  let fmtOffset = -1;
  let fmtSize = 0;
  let dataOffset = -1;
  let dataSize = 0;
  while (cursor + 8 <= view.byteLength) {
    const chunkId = readBigEndianUint32(view, cursor);
    const chunkSize = view.getUint32(cursor + 4, true);
    const payloadStart = cursor + 8;
    if (chunkId === FMT_CHUNK_ID) {
      fmtOffset = payloadStart;
      fmtSize = chunkSize;
    } else if (chunkId === DATA_CHUNK_ID) {
      dataOffset = payloadStart;
      dataSize = chunkSize;
      break;
    }
    cursor = payloadStart + chunkSize + (chunkSize % 2);
  }
  if (fmtOffset < 0 || fmtSize < 16) throw new Error("WAV header missing fmt chunk");
  if (dataOffset < 0) throw new Error("WAV header missing data chunk");

  const audioFormat = view.getUint16(fmtOffset, true);
  if (audioFormat !== PCM_FORMAT) throw new Error(`Unsupported WAV audio format: ${audioFormat}`);
  const channels = view.getUint16(fmtOffset + 2, true);
  const sampleRate = view.getUint32(fmtOffset + 4, true);
  const bitsPerSample = view.getUint16(fmtOffset + 14, true);
  const bytesPerSample = bitsPerSample / 8;
  const frameBytes = bytesPerSample * channels;
  const durationMs = frameBytes > 0 ? Math.floor(((dataSize / frameBytes) * 1000) / sampleRate) : 0;
  return { sampleRate, channels, bitsPerSample, dataOffset, dataLength: dataSize, durationMs };
}
