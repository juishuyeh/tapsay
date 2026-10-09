"""麥克風錄音：PCM 收在記憶體，停止時直接吐出 WAV bytes（不落地）。"""

from __future__ import annotations

import io
import wave

try:
    import sounddevice as sd
except OSError as _exc:  # Linux 沒裝 PortAudio 時 import 就會失敗；延到錄音時才報錯，程式照樣能開
    sd = None
    _IMPORT_ERROR = _exc

SAMPLE_RATE = 16000
CHANNELS = 1
SAMPLE_WIDTH = 2  # int16
MIN_SECONDS = 0.3


class RecorderError(RuntimeError):
    pass


class Recorder:
    def __init__(self) -> None:
        self._stream = None
        self._chunks: list[bytes] = []

    @property
    def is_recording(self) -> bool:
        return self._stream is not None

    def start(self) -> None:
        if self._stream is not None:
            return
        if sd is None:
            raise RecorderError(
                f"找不到 PortAudio（{_IMPORT_ERROR}）：請執行 sudo apt install libportaudio2"
            )
        self._chunks = []

        def callback(indata, frames, time_info, status):
            self._chunks.append(bytes(indata))

        try:
            stream = sd.RawInputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="int16",
                callback=callback,
            )
            stream.start()
        except Exception as exc:  # PortAudioError、沒有裝置、沒有權限
            raise RecorderError(f"無法使用麥克風：{exc}") from exc
        self._stream = stream

    def stop(self) -> bytes:
        """停止錄音並回傳 WAV bytes。"""
        stream, self._stream = self._stream, None
        if stream is None:
            raise RecorderError("目前沒有在錄音")
        try:
            stream.stop()
            stream.close()
        except Exception as exc:
            raise RecorderError(f"停止錄音失敗：{exc}") from exc

        pcm = b"".join(self._chunks)
        self._chunks = []
        seconds = len(pcm) / (SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH)
        if seconds < MIN_SECONDS:
            raise RecorderError("沒有錄到聲音")

        buf = io.BytesIO()
        with wave.open(buf, "wb") as wav:
            wav.setnchannels(CHANNELS)
            wav.setsampwidth(SAMPLE_WIDTH)
            wav.setframerate(SAMPLE_RATE)
            wav.writeframes(pcm)
        return buf.getvalue()

    def cancel(self) -> None:
        stream, self._stream = self._stream, None
        self._chunks = []
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass
