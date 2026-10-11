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
    let cancelled = false;

    const start = async () => {
      hlsRef.current?.destroy();
      hlsRef.current = null;

      if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = src;
      } else if (Hls.isSupported()) {
        const hls = new Hls({
          enableWorker: true,
          lowLatencyMode: true,
          backBufferLength: 30,
        });
        hlsRef.current = hls;
        hls.loadSource(src);
        hls.attachMedia(video);
        hls.on(Hls.Events.ERROR, (_e, data) => {
          if (data.fatal) setError("Playback failed");
        });
      } else {
        setError("HLS not supported");
        return;
      }

      if (autoPlay && !cancelled) {
        try {
          await video.play();
        } catch {
          /* autoplay may require gesture */
        }
      }
    };

    void start();
    return () => {
      cancelled = true;
      hlsRef.current?.destroy();
      hlsRef.current = null;
    };
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
    if (video.paused) await video.play().catch(() => undefined);
    else video.pause();
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
        // @ts-expect-error Safari AirPlay
        x-webkit-airplay="allow"
        controls={false}
        muted={muted}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onClick={() => setShowControls((v) => !v)}
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
      {src && !error && (
        <div className={`player-overlay ${showControls || !playing ? "is-visible" : ""}`}>
          <div className="top">
            <div className="title">{title}</div>
            <div style={{ display: "flex", gap: 8 }}>
              {/* Safari exposes AirPlay via the video element / system route picker */}
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
