"use client";

import { useEffect, useRef, useState } from "react";
import Hls from "hls.js";

type Props = {
  src: string | null;
  title: string;
  muted: boolean;
  onMutedChange: (muted: boolean) => void;
  fill?: boolean;
  className?: string;
  autoPlay?: boolean;
};

/** Try play; if the browser blocks unmuted autoplay, mute and retry. */
async function startPlayback(
  video: HTMLVideoElement,
  muted: boolean,
  onMutedChange: (muted: boolean) => void,
): Promise<boolean> {
  video.muted = muted;
  try {
    await video.play();
    return true;
  } catch {
    // Async resolve loses the click gesture — muted autoplay is allowed.
    if (!video.muted) {
      video.muted = true;
      onMutedChange(true);
      try {
        await video.play();
        return true;
      } catch {
        return false;
      }
    }
    return false;
  }
}

export function HlsPlayer({
  src,
  title,
  muted,
  onMutedChange,
  fill = false,
  className = "",
  autoPlay = true,
}: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const hlsRef = useRef<Hls | null>(null);
  const [showControls, setShowControls] = useState(true);
  const [playing, setPlaying] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pipSupported, setPipSupported] = useState(false);
  const [needsGesture, setNeedsGesture] = useState(false);

  useEffect(() => {
    setPipSupported(
      typeof document !== "undefined" &&
        "pictureInPictureEnabled" in document &&
        Boolean(document.pictureInPictureEnabled),
    );
  }, []);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || !src) return;
    setError(null);
    setNeedsGesture(false);
    let cancelled = false;

    const kickAutoplay = async () => {
      if (!autoPlay || cancelled) return;
      const ok = await startPlayback(video, muted, onMutedChange);
      if (!cancelled && !ok) setNeedsGesture(true);
    };

    const start = () => {
      hlsRef.current?.destroy();
      hlsRef.current = null;

      if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = src;
        const onReady = () => {
          video.removeEventListener("loadedmetadata", onReady);
          void kickAutoplay();
        };
        video.addEventListener("loadedmetadata", onReady);
        // Some Safari builds already have metadata cached.
        if (video.readyState >= 1) onReady();
      } else if (Hls.isSupported()) {
        const hls = new Hls({
          enableWorker: true,
          // LL-HLS stalls hard when the Workers HLS proxy is a hop behind the live edge.
          lowLatencyMode: false,
          liveSyncDurationCount: 3,
          liveMaxLatencyDurationCount: 10,
          maxBufferLength: 30,
          backBufferLength: 30,
        });
        hlsRef.current = hls;
        hls.loadSource(src);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, () => {
          void kickAutoplay();
        });
        hls.on(Hls.Events.ERROR, (_e, data) => {
          if (!data.fatal) return;
          switch (data.type) {
            case Hls.ErrorTypes.NETWORK_ERROR:
              hls.startLoad();
              break;
            case Hls.ErrorTypes.MEDIA_ERROR:
              hls.recoverMediaError();
              break;
            default:
              setError("Playback failed");
              break;
          }
        });
      } else {
        setError("HLS not supported");
      }
    };

    start();
    return () => {
      cancelled = true;
      hlsRef.current?.destroy();
      hlsRef.current = null;
    };
    // muted / onMutedChange intentionally omitted — autoplay path reads latest via closure on src change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [src, autoPlay]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    video.muted = muted;
  }, [muted]);

  useEffect(() => {
    if (!showControls || !playing) return;
    const t = window.setTimeout(() => setShowControls(false), 4000);
    return () => window.clearTimeout(t);
  }, [showControls, playing]);

  const togglePlay = async () => {
    const video = videoRef.current;
    if (!video) return;
    if (video.paused) {
      const ok = await startPlayback(video, muted, onMutedChange);
      if (ok) setNeedsGesture(false);
    } else {
      video.pause();
    }
  };

  const togglePiP = async () => {
    const video = videoRef.current;
    if (!video || !pipSupported) return;
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture();
      else await video.requestPictureInPicture();
    } catch {
      /* ignore */
    }
  };

  const enterFullscreen = async () => {
    const stage = videoRef.current?.parentElement;
    if (!stage) return;
    if (document.fullscreenElement) await document.exitFullscreen();
    else await stage.requestFullscreen().catch(() => undefined);
  };

  return (
    <div className={`player-stage ${fill ? "is-fill" : ""} ${className}`.trim()}>
      <video
        ref={videoRef}
        playsInline
        autoPlay={autoPlay}
        controls={false}
        muted={muted}
        onPlay={() => {
          setPlaying(true);
          setNeedsGesture(false);
        }}
        onPause={() => setPlaying(false)}
        onClick={() => setShowControls((v) => !v)}
        {...{ "x-webkit-airplay": "allow" }}
      />
      {!src && (
        <div className="placeholder">
          <div>
            <strong>Select a server</strong>
            <p>Choose a channel below to start the stream.</p>
          </div>
        </div>
      )}
      {src && error && (
        <div className="placeholder">
          <div>
            <strong>{error}</strong>
            <p>Try another server.</p>
          </div>
        </div>
      )}
      {src && !error && needsGesture && !playing && (
        <button type="button" className="placeholder" onClick={() => void togglePlay()} style={{ cursor: "pointer" }}>
          <div>
            <strong>Tap to play</strong>
            <p>Browser blocked autoplay — click to start.</p>
          </div>
        </button>
      )}
      {src && !error && (
        <div className={`player-overlay ${showControls || !playing ? "is-visible" : ""}`}>
          <div className="top">
            <div className="title">{title}</div>
            <div style={{ display: "flex", gap: 8 }}>
              <button
                type="button"
                className="ctrl"
                title="AirPlay (Safari)"
                onClick={() => {
                  const video = videoRef.current as HTMLVideoElement & {
                    webkitShowPlaybackTargetPicker?: () => void;
                  };
                  video?.webkitShowPlaybackTargetPicker?.();
                }}
              >
                ⧉
              </button>
              {pipSupported && (
                <button type="button" className="ctrl" title="Picture in Picture" onClick={() => void togglePiP()}>
                  ▭
                </button>
              )}
            </div>
          </div>
          <div className="bottom">
            <button type="button" className="ctrl" onClick={() => void togglePlay()} title={playing ? "Pause" : "Play"}>
              {playing ? "❚❚" : "▶"}
            </button>
            <div style={{ display: "flex", gap: 8 }}>
              <button
                type="button"
                className="ctrl"
                title={muted ? "Unmute" : "Mute"}
                onClick={() => onMutedChange(!muted)}
              >
                {muted ? "🔇" : "🔊"}
              </button>
              <button type="button" className="ctrl" title="Fullscreen" onClick={() => void enterFullscreen()}>
                ⛶
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
