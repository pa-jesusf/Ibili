use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{CoreError, CoreResult};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct OfflinePackagingRequest {
    pub diagnostics_dir: String,
    #[serde(default)]
    pub output_root_dir: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct OfflinePackagingPlan {
    pub diagnostics_dir: String,
    pub workspace_root_dir: String,
    pub stream_manifest_path: String,
    pub authoring_summary_path: String,
    pub source_kind: String,
    pub has_audio: bool,
    pub startup_ready: bool,
    pub staged_files: Vec<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct OfflinePackagingBuild {
    pub diagnostics_dir: String,
    pub workspace_root_dir: String,
    pub master_playlist_path: String,
    pub video_playlist_path: String,
    pub audio_playlist_path: Option<String>,
    pub stream_manifest_path: String,
    pub authoring_summary_path: String,
    pub source_kind: String,
    pub has_audio: bool,
    pub startup_ready: bool,
    pub staged_files: Vec<String>,
    pub generated_files: Vec<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Copy)]
enum SourceKind {
    ProxyDiagnostics,
    RemuxDiagnostics,
}

impl SourceKind {
    fn as_str(self) -> &'static str {
        match self {
            SourceKind::ProxyDiagnostics => "proxy_diagnostics",
            SourceKind::RemuxDiagnostics => "remux_diagnostics",
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum PackagingMode {
    Plan,
    Build,
}

impl PackagingMode {
    fn as_str(self) -> &'static str {
        match self {
            PackagingMode::Plan => "offline_plan",
            PackagingMode::Build => "offline_build",
        }
    }

    fn output_suffix(self) -> &'static str {
        match self {
            PackagingMode::Plan => "offline-plan",
            PackagingMode::Build => "offline-build",
        }
    }
}

#[derive(Debug)]
struct PreparedWorkspace {
    diagnostics_dir: PathBuf,
    workspace_root: PathBuf,
    source_kind: SourceKind,
    has_audio: bool,
    staged_inputs: Vec<StagedInput>,
    staged_files: Vec<String>,
    warnings: Vec<String>,
    metadata_hints: MetadataHints,
    video_template: MediaPlaylistTemplate,
    audio_template: Option<MediaPlaylistTemplate>,
    master_template: MasterPlaylistTemplate,
}

#[derive(Debug, Default)]
struct MetadataHints {
    video_codec: Option<String>,
    video_supplemental_codec: Option<String>,
    audio_codec: Option<String>,
    video_width: Option<u64>,
    video_height: Option<u64>,
    video_frame_rate: Option<String>,
    video_range: Option<String>,
}

#[derive(Debug, Clone, Copy)]
struct MediaPlaylistTemplate {
    target_duration: u64,
    first_segment_duration_sec: f64,
}

impl MediaPlaylistTemplate {
    fn new(target_duration: u64, first_segment_duration_sec: f64) -> Self {
        Self {
            target_duration: target_duration.max(1),
            first_segment_duration_sec: first_segment_duration_sec.max(0.001),
        }
    }
}

#[derive(Debug, Default)]
struct MasterPlaylistTemplate {
    bandwidth: Option<u64>,
    codecs: Option<String>,
}

#[derive(Debug, Serialize)]
struct StreamManifest {
    schema_version: u32,
    mode: &'static str,
    request_summary: RequestSummary,
    source_kind: String,
    has_audio: bool,
    startup_ready: bool,
    staged_inputs: Vec<StagedInput>,
    workspace_outputs: Vec<WorkspaceOutput>,
    playlist_summary: PlaylistSummary,
    validation_status: ValidationStatus,
    warnings: Vec<String>,
}

#[derive(Debug, Serialize)]
struct RequestSummary {
    diagnostics_dir: String,
    workspace_root_dir: String,
}

#[derive(Debug, Serialize)]
struct StagedInput {
    kind: String,
    source_path: String,
    staged_path: String,
    bytes: u64,
}

#[derive(Debug, Serialize)]
struct WorkspaceOutput {
    kind: String,
    path: String,
    status: String,
}

#[derive(Debug, Serialize)]
struct PlaylistSummary {
    video_target_duration: u64,
    video_first_segment_duration_sec: f64,
    audio_target_duration: Option<u64>,
    audio_first_segment_duration_sec: Option<f64>,
    master_bandwidth: Option<u64>,
    master_codec_string: Option<String>,
}

#[derive(Debug, Serialize)]
struct ValidationStatus {
    status: String,
    startup_ready: bool,
    notes: Vec<String>,
}

#[derive(Debug, Serialize)]
struct AuthoringSummary {
    mode: &'static str,
    status: &'static str,
    startup_ready: bool,
    master_playlist_path: String,
    notes: Vec<String>,
}

#[derive(Debug)]
struct AuthoredWorkspace {
    master_playlist_path: PathBuf,
    video_playlist_path: PathBuf,
    audio_playlist_path: Option<PathBuf>,
    generated_files: Vec<String>,
    playlist_summary: PlaylistSummary,
    startup_ready: bool,
    warnings: Vec<String>,
}

pub fn offline_plan(request: OfflinePackagingRequest) -> CoreResult<OfflinePackagingPlan> {
    let prepared = prepare_workspace(&request, PackagingMode::Plan)?;
    let mut warnings = prepared.warnings.clone();
    warnings.push(
        "planning-only workspace: authored playlists are deferred until packaging.offline_build"
            .to_string(),
    );

    let stream_manifest_path = prepared.workspace_root.join("stream-manifest.json");
    let authoring_summary_path = prepared.workspace_root.join("authoring-summary.json");
    let workspace_outputs = workspace_outputs_for(&prepared.workspace_root, prepared.has_audio, "pending_authoring");
    let playlist_summary = playlist_summary_for(
        &prepared,
        None,
        prepared.master_template.bandwidth.unwrap_or(2_000_000),
    );
    let manifest = StreamManifest {
        schema_version: 1,
        mode: PackagingMode::Plan.as_str(),
        request_summary: RequestSummary {
            diagnostics_dir: prepared.diagnostics_dir.display().to_string(),
            workspace_root_dir: prepared.workspace_root.display().to_string(),
        },
        source_kind: prepared.source_kind.as_str().to_string(),
        has_audio: prepared.has_audio,
        startup_ready: false,
        staged_inputs: prepared.staged_inputs,
        workspace_outputs,
        playlist_summary,
        validation_status: ValidationStatus {
            status: "planning_only".to_string(),
            startup_ready: false,
            notes: warnings.clone(),
        },
        warnings: warnings.clone(),
    };
    let authoring_summary = AuthoringSummary {
        mode: PackagingMode::Plan.as_str(),
        status: "not_started",
        startup_ready: false,
        master_playlist_path: prepared.workspace_root.join("master.m3u8").display().to_string(),
        notes: warnings.clone(),
    };

    write_json(&stream_manifest_path, &manifest)?;
    write_json(&authoring_summary_path, &authoring_summary)?;

    Ok(OfflinePackagingPlan {
        diagnostics_dir: prepared.diagnostics_dir.display().to_string(),
        workspace_root_dir: prepared.workspace_root.display().to_string(),
        stream_manifest_path: stream_manifest_path.display().to_string(),
        authoring_summary_path: authoring_summary_path.display().to_string(),
        source_kind: prepared.source_kind.as_str().to_string(),
        has_audio: prepared.has_audio,
        startup_ready: false,
        staged_files: prepared.staged_files,
        warnings,
    })
}

pub fn offline_build(request: OfflinePackagingRequest) -> CoreResult<OfflinePackagingBuild> {
    let prepared = prepare_workspace(&request, PackagingMode::Build)?;
    let authored = author_local_hls_workspace(&prepared)?;

    let mut warnings = prepared.warnings.clone();
    warnings.extend(authored.warnings.clone());

    let stream_manifest_path = prepared.workspace_root.join("stream-manifest.json");
    let authoring_summary_path = prepared.workspace_root.join("authoring-summary.json");
    let validation_status = if authored.startup_ready {
        ValidationStatus {
            status: "ready_for_avplayer_smoke_test".to_string(),
            startup_ready: true,
            notes: warnings.clone(),
        }
    } else {
        ValidationStatus {
            status: "authoring_incomplete".to_string(),
            startup_ready: false,
            notes: warnings.clone(),
        }
    };
    let workspace_outputs = workspace_outputs_for(
        &prepared.workspace_root,
        prepared.has_audio,
        if authored.startup_ready { "ready" } else { "incomplete" },
    );
    let manifest = StreamManifest {
        schema_version: 1,
        mode: PackagingMode::Build.as_str(),
        request_summary: RequestSummary {
            diagnostics_dir: prepared.diagnostics_dir.display().to_string(),
            workspace_root_dir: prepared.workspace_root.display().to_string(),
        },
        source_kind: prepared.source_kind.as_str().to_string(),
        has_audio: prepared.has_audio,
        startup_ready: authored.startup_ready,
        staged_inputs: prepared.staged_inputs,
        workspace_outputs,
        playlist_summary: authored.playlist_summary,
        validation_status,
        warnings: warnings.clone(),
    };
    let authoring_summary = AuthoringSummary {
        mode: PackagingMode::Build.as_str(),
        status: if authored.startup_ready {
            "ready_for_avplayer_smoke_test"
        } else {
            "incomplete"
        },
        startup_ready: authored.startup_ready,
        master_playlist_path: authored.master_playlist_path.display().to_string(),
        notes: warnings.clone(),
    };

    write_json(&stream_manifest_path, &manifest)?;
    write_json(&authoring_summary_path, &authoring_summary)?;

    let mut generated_files = authored.generated_files;
    generated_files.push(stream_manifest_path.display().to_string());
    generated_files.push(authoring_summary_path.display().to_string());

    Ok(OfflinePackagingBuild {
        diagnostics_dir: prepared.diagnostics_dir.display().to_string(),
        workspace_root_dir: prepared.workspace_root.display().to_string(),
        master_playlist_path: authored.master_playlist_path.display().to_string(),
        video_playlist_path: authored.video_playlist_path.display().to_string(),
        audio_playlist_path: authored
            .audio_playlist_path
            .as_ref()
            .map(|path| path.display().to_string()),
        stream_manifest_path: stream_manifest_path.display().to_string(),
        authoring_summary_path: authoring_summary_path.display().to_string(),
        source_kind: prepared.source_kind.as_str().to_string(),
        has_audio: prepared.has_audio,
        startup_ready: authored.startup_ready,
        staged_files: prepared.staged_files,
        generated_files,
        warnings,
    })
}

fn prepare_workspace(
    request: &OfflinePackagingRequest,
    mode: PackagingMode,
) -> CoreResult<PreparedWorkspace> {
    let diagnostics_dir = PathBuf::from(&request.diagnostics_dir);
    if !diagnostics_dir.is_dir() {
        return Err(CoreError::InvalidArgument(format!(
            "diagnostics_dir is not a directory: {}",
            diagnostics_dir.display()
        )));
    }

    let source_kind = detect_source_kind(&diagnostics_dir)?;
    let workspace_root = resolve_workspace_root(&diagnostics_dir, &request.output_root_dir, mode)?;
    if workspace_root.exists() {
        fs::remove_dir_all(&workspace_root).map_err(|error| {
            CoreError::Internal(format!(
                "remove existing workspace {}: {error}",
                workspace_root.display()
            ))
        })?;
    }
    fs::create_dir_all(workspace_root.join("diagnostics")).map_err(|error| {
        CoreError::Internal(format!(
            "create workspace {}: {error}",
            workspace_root.display()
        ))
    })?;

    let metadata_path = diagnostics_dir.join("metadata.json");
    let metadata_hints = read_metadata_hints(&metadata_path)?;

    let mut staged_inputs = Vec::new();
    let mut staged_files = Vec::new();
    let mut warnings = vec![
        "workspace contains only staged leading diagnostics segment(s); use it for AVPlayer smoke tests, not full-asset validation"
            .to_string(),
    ];

    stage_required(
        &metadata_path,
        &workspace_root.join("diagnostics/metadata.json"),
        "metadata",
        &mut staged_inputs,
        &mut staged_files,
    )?;

    let (has_audio, video_template, audio_template, master_template) = match source_kind {
        SourceKind::ProxyDiagnostics => prepare_proxy_workspace(
            &diagnostics_dir,
            &workspace_root,
            &mut staged_inputs,
            &mut staged_files,
            &mut warnings,
        )?,
        SourceKind::RemuxDiagnostics => prepare_remux_workspace(
            &diagnostics_dir,
            &workspace_root,
            &mut staged_inputs,
            &mut staged_files,
            &mut warnings,
        )?,
    };

    if metadata_hints.video_codec.is_none() && !matches!(source_kind, SourceKind::RemuxDiagnostics) {
        warnings.push("metadata.json did not provide videoCodec; master playlist will fall back to source master codecs when available".to_string());
    }
    if has_audio && metadata_hints.audio_codec.is_none() && !matches!(source_kind, SourceKind::RemuxDiagnostics) {
        warnings.push("metadata.json did not provide audioCodec; master playlist will fall back to source master codecs when available".to_string());
    }
    if matches!(source_kind, SourceKind::RemuxDiagnostics) {
        warnings.push("remux diagnostics remain comparison-only; passing this build does not validate the long-term live packager path".to_string());
    }

    Ok(PreparedWorkspace {
        diagnostics_dir,
        workspace_root,
        source_kind,
        has_audio,
        staged_inputs,
        staged_files,
        warnings,
        metadata_hints,
        video_template,
        audio_template,
        master_template,
    })
}

fn prepare_proxy_workspace(
    diagnostics_dir: &Path,
    workspace_root: &Path,
    staged_inputs: &mut Vec<StagedInput>,
    staged_files: &mut Vec<String>,
    warnings: &mut Vec<String>,
) -> CoreResult<(bool, MediaPlaylistTemplate, Option<MediaPlaylistTemplate>, MasterPlaylistTemplate)> {
    stage_required(
        &diagnostics_dir.join("video-init.mp4"),
        &workspace_root.join("init-video.mp4"),
        "video_init",
        staged_inputs,
        staged_files,
    )?;
    stage_required(
        &diagnostics_dir.join("video-fragment-000.m4s"),
        &workspace_root.join("v-seg-00000.m4s"),
        "video_segment_0",
        staged_inputs,
        staged_files,
    )?;
    stage_optional(
        &diagnostics_dir.join("video-init-diagnostics.json"),
        &workspace_root.join("diagnostics/video-init-diagnostics.json"),
        "video_init_diagnostics",
        staged_inputs,
        staged_files,
    )?;
    stage_optional(
        &diagnostics_dir.join("video-fragment-000-diagnostics.json"),
        &workspace_root.join("diagnostics/video-fragment-000-diagnostics.json"),
        "video_fragment_0_diagnostics",
        staged_inputs,
        staged_files,
    )?;

    let audio_present = diagnostics_dir.join("audio-init.mp4").is_file()
        && diagnostics_dir.join("audio-fragment-000.m4s").is_file();
    if audio_present {
        stage_required(
            &diagnostics_dir.join("audio-init.mp4"),
            &workspace_root.join("init-audio.mp4"),
            "audio_init",
            staged_inputs,
            staged_files,
        )?;
        stage_required(
            &diagnostics_dir.join("audio-fragment-000.m4s"),
            &workspace_root.join("a-seg-00000.m4s"),
            "audio_segment_0",
            staged_inputs,
            staged_files,
        )?;
        stage_optional(
            &diagnostics_dir.join("audio-fragment-000-diagnostics.json"),
            &workspace_root.join("diagnostics/audio-fragment-000-diagnostics.json"),
            "audio_fragment_0_diagnostics",
            staged_inputs,
            staged_files,
        )?;
    }

    stage_original_playlist(diagnostics_dir, workspace_root, "master.m3u8", staged_inputs, staged_files)?;
    stage_original_playlist(diagnostics_dir, workspace_root, "video.m3u8", staged_inputs, staged_files)?;
    stage_original_playlist(diagnostics_dir, workspace_root, "audio.m3u8", staged_inputs, staged_files)?;

    let video_template = parse_media_playlist_template(&diagnostics_dir.join("video.m3u8")).unwrap_or_else(|| {
        warnings.push("source video.m3u8 was missing or incomplete; using 5.0s fallback for the first video segment".to_string());
        MediaPlaylistTemplate::new(6, 5.0)
    });
    let audio_template = if audio_present {
        Some(parse_media_playlist_template(&diagnostics_dir.join("audio.m3u8")).unwrap_or_else(|| {
            warnings.push("source audio.m3u8 was missing or incomplete; using 5.0s fallback for the first audio segment".to_string());
            MediaPlaylistTemplate::new(6, 5.0)
        }))
    } else {
        None
    };
    let master_template = parse_master_playlist_template(&diagnostics_dir.join("master.m3u8")).unwrap_or_default();

    Ok((audio_present, video_template, audio_template, master_template))
}

fn prepare_remux_workspace(
    diagnostics_dir: &Path,
    workspace_root: &Path,
    staged_inputs: &mut Vec<StagedInput>,
    staged_files: &mut Vec<String>,
    warnings: &mut Vec<String>,
) -> CoreResult<(bool, MediaPlaylistTemplate, Option<MediaPlaylistTemplate>, MasterPlaylistTemplate)> {
    stage_required(
        &diagnostics_dir.join("init.mp4"),
        &workspace_root.join("init-video.mp4"),
        "video_init",
        staged_inputs,
        staged_files,
    )?;
    stage_required(
        &diagnostics_dir.join("seg-0.m4s"),
        &workspace_root.join("v-seg-00000.m4s"),
        "video_segment_0",
        staged_inputs,
        staged_files,
    )?;
    stage_original_playlist(diagnostics_dir, workspace_root, "live.m3u8", staged_inputs, staged_files)?;
    stage_original_playlist(diagnostics_dir, workspace_root, "local.m3u8", staged_inputs, staged_files)?;

    let video_template = parse_media_playlist_template(&diagnostics_dir.join("local.m3u8"))
        .or_else(|| parse_media_playlist_template(&diagnostics_dir.join("live.m3u8")))
        .unwrap_or_else(|| {
            warnings.push("source remux playlist was missing or incomplete; using 10.01s fallback for the first segment".to_string());
            MediaPlaylistTemplate::new(10, 10.01)
        });

    Ok((false, video_template, None, MasterPlaylistTemplate::default()))
}

fn author_local_hls_workspace(prepared: &PreparedWorkspace) -> CoreResult<AuthoredWorkspace> {
    let shared_target_duration = prepared
        .audio_template
        .map(|template| prepared.video_template.target_duration.max(template.target_duration))
        .unwrap_or(prepared.video_template.target_duration);
    let video_playlist_path = prepared.workspace_root.join("video.m3u8");
    write_text(
        &video_playlist_path,
        &build_media_playlist(
            "init-video.mp4",
            "v-seg-00000.m4s",
            prepared.video_template,
            shared_target_duration,
        ),
    )?;

    let mut generated_files = vec![video_playlist_path.display().to_string()];
    let mut authoring_warnings = Vec::new();

    let audio_playlist_path = if prepared.has_audio {
        let template = prepared.audio_template.unwrap_or(MediaPlaylistTemplate::new(6, 5.0));
        let path = prepared.workspace_root.join("audio.m3u8");
        write_text(
            &path,
            &build_media_playlist(
                "init-audio.mp4",
                "a-seg-00000.m4s",
                template,
                shared_target_duration,
            ),
        )?;
        generated_files.push(path.display().to_string());
        Some(path)
    } else {
        None
    };

    let master_codec_string = resolve_master_codec_string(
        prepared.has_audio,
        &prepared.metadata_hints,
        &prepared.master_template,
    );
    let master_bandwidth = resolve_master_bandwidth(prepared);
    if master_codec_string.is_none() {
        authoring_warnings.push(
            "master playlist omits CODECS because diagnostics metadata did not provide a reliable codec string"
                .to_string(),
        );
    }

    let master_playlist_path = prepared.workspace_root.join("master.m3u8");
    write_text(
        &master_playlist_path,
        &build_master_playlist(
            prepared.has_audio,
            master_bandwidth,
            master_codec_string.as_deref(),
            prepared.metadata_hints.video_supplemental_codec.as_deref(),
            prepared
                .metadata_hints
                .video_width
                .zip(prepared.metadata_hints.video_height),
            prepared.metadata_hints.video_frame_rate.as_deref(),
            prepared.metadata_hints.video_range.as_deref(),
        ),
    )?;
    generated_files.push(master_playlist_path.display().to_string());

    Ok(AuthoredWorkspace {
        master_playlist_path,
        video_playlist_path,
        audio_playlist_path,
        generated_files,
        playlist_summary: playlist_summary_for(prepared, master_codec_string, master_bandwidth),
        startup_ready: true,
        warnings: authoring_warnings,
    })
}

fn detect_source_kind(diagnostics_dir: &Path) -> CoreResult<SourceKind> {
    let proxy = diagnostics_dir.join("video-init.mp4").is_file()
        && diagnostics_dir.join("video-fragment-000.m4s").is_file();
    if proxy {
        return Ok(SourceKind::ProxyDiagnostics);
    }

    let remux = diagnostics_dir.join("init.mp4").is_file()
        && diagnostics_dir.join("seg-0.m4s").is_file();
    if remux {
        return Ok(SourceKind::RemuxDiagnostics);
    }

    Err(CoreError::InvalidArgument(format!(
        "unsupported diagnostics layout in {}",
        diagnostics_dir.display()
    )))
}

fn resolve_workspace_root(
    diagnostics_dir: &Path,
    output_root_dir: &str,
    mode: PackagingMode,
) -> CoreResult<PathBuf> {
    if output_root_dir.trim().is_empty() {
        return Ok(diagnostics_dir.join("packaging-workspace"));
    }
    let diagnostics_name = diagnostics_dir
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("diagnostics");
    Ok(PathBuf::from(output_root_dir).join(format!(
        "{diagnostics_name}-{}",
        mode.output_suffix()
    )))
}

fn stage_required(
    source: &Path,
    destination: &Path,
    kind: &str,
    staged_inputs: &mut Vec<StagedInput>,
    staged_files: &mut Vec<String>,
) -> CoreResult<()> {
    if !source.is_file() {
        return Err(CoreError::InvalidArgument(format!(
            "missing required file: {}",
            source.display()
        )));
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CoreError::Internal(format!("create {}: {error}", parent.display()))
        })?;
    }
    fs::copy(source, destination).map_err(|error| {
        CoreError::Internal(format!(
            "copy {} -> {}: {error}",
            source.display(),
            destination.display()
        ))
    })?;
    let bytes = fs::metadata(destination)
        .map_err(|error| CoreError::Internal(format!("metadata {}: {error}", destination.display())))?
        .len();
    staged_inputs.push(StagedInput {
        kind: kind.to_string(),
        source_path: source.display().to_string(),
        staged_path: destination.display().to_string(),
        bytes,
    });
    staged_files.push(destination.display().to_string());
    Ok(())
}

fn stage_optional(
    source: &Path,
    destination: &Path,
    kind: &str,
    staged_inputs: &mut Vec<StagedInput>,
    staged_files: &mut Vec<String>,
) -> CoreResult<bool> {
    if !source.is_file() {
        return Ok(false);
    }
    stage_required(source, destination, kind, staged_inputs, staged_files)?;
    Ok(true)
}

fn stage_original_playlist(
    diagnostics_dir: &Path,
    workspace_root: &Path,
    file_name: &str,
    staged_inputs: &mut Vec<StagedInput>,
    staged_files: &mut Vec<String>,
) -> CoreResult<()> {
    let source = diagnostics_dir.join(file_name);
    if !source.is_file() {
        return Ok(());
    }
    let destination = workspace_root.join("diagnostics").join(format!("original-{file_name}"));
    stage_required(
        &source,
        &destination,
        &format!("original_{file_name}"),
        staged_inputs,
        staged_files,
    )
}

fn workspace_outputs_for(workspace_root: &Path, has_audio: bool, status: &str) -> Vec<WorkspaceOutput> {
    let mut outputs = vec![
        WorkspaceOutput {
            kind: "master_playlist".to_string(),
            path: workspace_root.join("master.m3u8").display().to_string(),
            status: status.to_string(),
        },
        WorkspaceOutput {
            kind: "video_playlist".to_string(),
            path: workspace_root.join("video.m3u8").display().to_string(),
            status: status.to_string(),
        },
    ];
    if has_audio {
        outputs.push(WorkspaceOutput {
            kind: "audio_playlist".to_string(),
            path: workspace_root.join("audio.m3u8").display().to_string(),
            status: status.to_string(),
        });
    }
    outputs
}

fn playlist_summary_for(
    prepared: &PreparedWorkspace,
    master_codec_string: Option<String>,
    master_bandwidth: u64,
) -> PlaylistSummary {
    PlaylistSummary {
        video_target_duration: prepared.video_template.target_duration,
        video_first_segment_duration_sec: prepared.video_template.first_segment_duration_sec,
        audio_target_duration: prepared.audio_template.map(|template| template.target_duration),
        audio_first_segment_duration_sec: prepared
            .audio_template
            .map(|template| template.first_segment_duration_sec),
        master_bandwidth: Some(master_bandwidth),
        master_codec_string,
    }
}

fn read_metadata_hints(path: &Path) -> CoreResult<MetadataHints> {
    let bytes = fs::read(path)
        .map_err(|error| CoreError::Internal(format!("read {}: {error}", path.display())))?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|error| CoreError::Internal(format!("parse {}: {error}", path.display())))?;
    Ok(MetadataHints {
        video_codec: read_json_string(&value, "videoCodec"),
        video_supplemental_codec: read_json_string(&value, "videoSupplementalCodec"),
        audio_codec: read_json_string(&value, "audioCodec"),
        video_width: read_json_u64(&value, "videoWidth"),
        video_height: read_json_u64(&value, "videoHeight"),
        video_frame_rate: read_json_string(&value, "videoFrameRate"),
        video_range: read_json_string(&value, "videoRange"),
    })
}

fn read_json_string(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn read_json_u64(value: &Value, key: &str) -> Option<u64> {
    value.get(key).and_then(Value::as_u64)
}

fn parse_media_playlist_template(path: &Path) -> Option<MediaPlaylistTemplate> {
    let text = fs::read_to_string(path).ok()?;
    let mut target_duration = None;
    let mut first_segment_duration_sec = None;

    for line in text.lines() {
        if let Some(raw) = line.strip_prefix("#EXT-X-TARGETDURATION:") {
            target_duration = raw.trim().parse::<u64>().ok();
        } else if let Some(raw) = line.strip_prefix("#EXTINF:") {
            let value = raw
                .split_once(',')
                .map(|(value, _)| value)
                .unwrap_or(raw)
                .trim()
                .parse::<f64>()
                .ok();
            if value.is_some() {
                first_segment_duration_sec = value;
                break;
            }
        }
    }

    let first_segment_duration_sec = first_segment_duration_sec?;
    let effective_target_duration = target_duration.unwrap_or_else(|| first_segment_duration_sec.ceil() as u64);
    Some(MediaPlaylistTemplate::new(
        effective_target_duration,
        first_segment_duration_sec,
    ))
}

fn parse_master_playlist_template(path: &Path) -> Option<MasterPlaylistTemplate> {
    let text = fs::read_to_string(path).ok()?;
    for line in text.lines() {
        let attributes = match line.strip_prefix("#EXT-X-STREAM-INF:") {
            Some(raw) => parse_hls_attribute_list(raw),
            None => continue,
        };
        let bandwidth = attributes
            .iter()
            .find_map(|(key, value)| (key == "BANDWIDTH").then(|| value.parse::<u64>().ok()))
            .flatten();
        let codecs = attributes
            .iter()
            .find_map(|(key, value)| (key == "CODECS").then(|| value.clone()))
            .filter(|value| !value.is_empty());
        return Some(MasterPlaylistTemplate { bandwidth, codecs });
    }
    None
}

fn parse_hls_attribute_list(raw: &str) -> Vec<(String, String)> {
    let mut attributes = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;

    for ch in raw.chars() {
        match ch {
            '"' => {
                in_quotes = !in_quotes;
                current.push(ch);
            }
            ',' if !in_quotes => {
                if !current.trim().is_empty() {
                    attributes.push(current.trim().to_string());
                }
                current.clear();
            }
            _ => current.push(ch),
        }
    }
    if !current.trim().is_empty() {
        attributes.push(current.trim().to_string());
    }

    attributes
        .into_iter()
        .filter_map(|entry| {
            let (key, value) = entry.split_once('=')?;
            Some((
                key.trim().to_string(),
                value.trim().trim_matches('"').to_string(),
            ))
        })
        .collect()
}

fn resolve_master_codec_string(
    has_audio: bool,
    metadata_hints: &MetadataHints,
    master_template: &MasterPlaylistTemplate,
) -> Option<String> {
    match (
        metadata_hints.video_codec.as_deref(),
        metadata_hints.audio_codec.as_deref(),
        has_audio,
    ) {
        (Some(video_codec), Some(audio_codec), true) => {
            Some(format!("{video_codec},{audio_codec}"))
        }
        (Some(video_codec), _, false) => Some(video_codec.to_string()),
        _ => master_template.codecs.clone().filter(|value| !value.trim().is_empty()),
    }
}

fn resolve_master_bandwidth(prepared: &PreparedWorkspace) -> u64 {
    measured_segment_bandwidth(prepared)
        .unwrap_or_else(|| prepared.master_template.bandwidth.unwrap_or(2_000_000))
        .max(1)
}

fn measured_segment_bandwidth(prepared: &PreparedWorkspace) -> Option<u64> {
    let video_bytes = staged_input_bytes(&prepared.staged_inputs, "video_segment_0")?;
    let audio_bytes = staged_input_bytes(&prepared.staged_inputs, "audio_segment_0").unwrap_or(0);
    let duration = prepared
        .audio_template
        .map(|audio_template| {
            prepared
                .video_template
                .first_segment_duration_sec
                .max(audio_template.first_segment_duration_sec)
        })
        .unwrap_or(prepared.video_template.first_segment_duration_sec)
        .max(0.001);
    let bits_per_second = ((video_bytes + audio_bytes) as f64 * 8.0) / duration;
    Some(bits_per_second.ceil() as u64)
}

fn staged_input_bytes(staged_inputs: &[StagedInput], kind: &str) -> Option<u64> {
    staged_inputs
        .iter()
        .find(|input| input.kind == kind)
        .map(|input| input.bytes)
}

fn build_master_playlist(
    has_audio: bool,
    bandwidth: u64,
    codec_string: Option<&str>,
    supplemental_codec_string: Option<&str>,
    resolution: Option<(u64, u64)>,
    frame_rate: Option<&str>,
    video_range: Option<&str>,
) -> String {
    let mut output = String::from("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n");
    if has_audio {
        output.push_str(
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"default\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n",
        );
    }
    output.push_str(&format!("#EXT-X-STREAM-INF:BANDWIDTH={}", bandwidth.max(1)));
    output.push_str(&format!(",AVERAGE-BANDWIDTH={}", bandwidth.max(1)));
    if let Some(codec_string) = codec_string {
        output.push_str(&format!(",CODECS=\"{}\"", codec_string));
    }
    if let Some(supplemental_codec_string) = supplemental_codec_string.filter(|value| !value.trim().is_empty()) {
        output.push_str(&format!(",SUPPLEMENTAL-CODECS=\"{}\"", supplemental_codec_string.trim()));
    }
    if let Some((width, height)) = resolution {
        output.push_str(&format!(",RESOLUTION={}x{}", width, height));
    }
    if let Some(frame_rate) = frame_rate.filter(|value| !value.trim().is_empty()) {
        output.push_str(&format!(",FRAME-RATE={}", frame_rate.trim()));
    }
    if let Some(video_range) = video_range.filter(|value| !value.trim().is_empty()) {
        output.push_str(&format!(",VIDEO-RANGE={}", video_range.trim()));
    }
    if has_audio {
        output.push_str(",AUDIO=\"aud\"");
    }
    output.push_str("\nvideo.m3u8\n");
    output
}

fn build_media_playlist(
    init_uri: &str,
    segment_uri: &str,
    template: MediaPlaylistTemplate,
    target_duration_override: u64,
) -> String {
    let target_duration = target_duration_override
        .max(template.target_duration)
        .max(template.first_segment_duration_sec.ceil() as u64)
        .max(1);
    format!(
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:{target_duration}\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"{init_uri}\"\n#EXTINF:{:.6},\n{segment_uri}\n#EXT-X-ENDLIST\n",
        template.first_segment_duration_sec
    )
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> CoreResult<()> {
    let bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| CoreError::Internal(format!("serialize {}: {error}", path.display())))?;
    fs::write(path, bytes)
        .map_err(|error| CoreError::Internal(format!("write {}: {error}", path.display())))
}

fn write_text(path: &Path, value: &str) -> CoreResult<()> {
    fs::write(path, value)
        .map_err(|error| CoreError::Internal(format!("write {}: {error}", path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn offline_plan_stages_proxy_diagnostics_inputs() {
        let diagnostics_dir = make_temp_dir("proxy");
        write_file(&diagnostics_dir.join("metadata.json"), b"{}");
        write_file(&diagnostics_dir.join("video-init.mp4"), b"video-init");
        write_file(&diagnostics_dir.join("video-fragment-000.m4s"), b"video-seg");
        write_file(&diagnostics_dir.join("audio-init.mp4"), b"audio-init");
        write_file(&diagnostics_dir.join("audio-fragment-000.m4s"), b"audio-seg");
        write_file(&diagnostics_dir.join("master.m3u8"), b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"hvc1.2.4.L153.90,mp4a.40.2\",AUDIO=\"aud\"\nvideo.m3u8\n");
        write_file(&diagnostics_dir.join("video.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.005000,\nv.seg\n");
        write_file(&diagnostics_dir.join("audio.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:4.992000,\na.seg\n");

        let plan = offline_plan(OfflinePackagingRequest {
            diagnostics_dir: diagnostics_dir.display().to_string(),
            output_root_dir: String::new(),
        })
        .expect("offline plan should succeed");

        assert_eq!(plan.source_kind, "proxy_diagnostics");
        assert!(plan.has_audio);
        assert!(!plan.startup_ready);
        assert!(Path::new(&plan.stream_manifest_path).is_file());
        assert!(Path::new(&plan.authoring_summary_path).is_file());
        assert!(Path::new(&plan.workspace_root_dir).join("init-video.mp4").is_file());
        assert!(Path::new(&plan.workspace_root_dir).join("v-seg-00000.m4s").is_file());
        assert!(Path::new(&plan.workspace_root_dir).join("init-audio.mp4").is_file());
        assert!(Path::new(&plan.workspace_root_dir).join("a-seg-00000.m4s").is_file());

        cleanup_dir(Path::new(&plan.workspace_root_dir));
        cleanup_dir(&diagnostics_dir);
    }

    #[test]
    fn offline_plan_stages_remux_diagnostics_inputs() {
        let diagnostics_dir = make_temp_dir("remux");
        write_file(&diagnostics_dir.join("metadata.json"), b"{}");
        write_file(&diagnostics_dir.join("init.mp4"), b"video-init");
        write_file(&diagnostics_dir.join("seg-0.m4s"), b"video-seg");
        write_file(&diagnostics_dir.join("local.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.010000,\nseg-0.m4s\n");

        let plan = offline_plan(OfflinePackagingRequest {
            diagnostics_dir: diagnostics_dir.display().to_string(),
            output_root_dir: String::new(),
        })
        .expect("offline plan should succeed");

        assert_eq!(plan.source_kind, "remux_diagnostics");
        assert!(!plan.has_audio);
        assert!(Path::new(&plan.workspace_root_dir).join("init-video.mp4").is_file());
        assert!(Path::new(&plan.workspace_root_dir).join("v-seg-00000.m4s").is_file());
        assert!(Path::new(&plan.workspace_root_dir).join("diagnostics/original-local.m3u8").is_file());

        cleanup_dir(Path::new(&plan.workspace_root_dir));
        cleanup_dir(&diagnostics_dir);
    }

    #[test]
    fn offline_build_authors_local_hls_workspace_for_proxy_diagnostics() {
        let diagnostics_dir = make_temp_dir("proxy-build");
        write_file(
            &diagnostics_dir.join("metadata.json"),
            br#"{"videoCodec":"hvc1.2.4.L153.90","audioCodec":"mp4a.40.2","videoWidth":3840,"videoHeight":2160,"videoFrameRate":"59.940","videoRange":"PQ"}"#,
        );
        write_file(&diagnostics_dir.join("video-init.mp4"), b"video-init");
        write_file(&diagnostics_dir.join("video-fragment-000.m4s"), b"video-seg");
        write_file(&diagnostics_dir.join("audio-init.mp4"), b"audio-init");
        write_file(&diagnostics_dir.join("audio-fragment-000.m4s"), b"audio-seg");
        write_file(&diagnostics_dir.join("master.m3u8"), b"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"default\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"hvc1.2.4.L153.90,mp4a.40.2\",AUDIO=\"aud\"\nvideo.m3u8\n");
        write_file(&diagnostics_dir.join("video.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.005000,\nv.seg\n");
        write_file(&diagnostics_dir.join("audio.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:4.992000,\na.seg\n");

        let build = offline_build(OfflinePackagingRequest {
            diagnostics_dir: diagnostics_dir.display().to_string(),
            output_root_dir: String::new(),
        })
        .expect("offline build should succeed");

        assert!(build.startup_ready);
        assert_eq!(build.source_kind, "proxy_diagnostics");
        assert_eq!(
            read_text(Path::new(&build.video_playlist_path)),
            "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init-video.mp4\"\n#EXTINF:5.005000,\nv-seg-00000.m4s\n#EXT-X-ENDLIST\n"
        );
        assert_eq!(
            read_text(Path::new(build.audio_playlist_path.as_deref().unwrap())),
            "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init-audio.mp4\"\n#EXTINF:4.992000,\na-seg-00000.m4s\n#EXT-X-ENDLIST\n"
        );
        let master_text = read_text(Path::new(&build.master_playlist_path));
        assert!(master_text.contains("#EXT-X-INDEPENDENT-SEGMENTS"));
        assert!(master_text.contains("BANDWIDTH=29,AVERAGE-BANDWIDTH=29"));
        assert!(master_text.contains("CODECS=\"hvc1.2.4.L153.90,mp4a.40.2\""));
        assert!(master_text.contains("RESOLUTION=3840x2160"));
        assert!(master_text.contains("FRAME-RATE=59.940"));
        assert!(master_text.contains("VIDEO-RANGE=PQ"));

        cleanup_dir(Path::new(&build.workspace_root_dir));
        cleanup_dir(&diagnostics_dir);
    }

    #[test]
    fn offline_build_authors_supplemental_codecs_for_dolby_vision_hlg() {
        let diagnostics_dir = make_temp_dir("proxy-build-dv-hlg");
        write_file(
            &diagnostics_dir.join("metadata.json"),
            br#"{"videoCodec":"hvc1.2.20000000.L153.90","videoSupplementalCodec":"dvh1.08.09/db4h","audioCodec":"mp4a.40.2","videoWidth":4096,"videoHeight":2160,"videoFrameRate":"50.000","videoRange":"HLG"}"#,
        );
        write_file(&diagnostics_dir.join("video-init.mp4"), b"video-init");
        write_file(&diagnostics_dir.join("video-fragment-000.m4s"), b"video-seg");
        write_file(&diagnostics_dir.join("audio-init.mp4"), b"audio-init");
        write_file(&diagnostics_dir.join("audio-fragment-000.m4s"), b"audio-seg");
        write_file(&diagnostics_dir.join("master.m3u8"), b"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"default\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"hvc1.2.20000000.L153.90,mp4a.40.2\",AUDIO=\"aud\"\nvideo.m3u8\n");
        write_file(&diagnostics_dir.join("video.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.000000,\nv.seg\n");
        write_file(&diagnostics_dir.join("audio.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:4.992000,\na.seg\n");

        let build = offline_build(OfflinePackagingRequest {
            diagnostics_dir: diagnostics_dir.display().to_string(),
            output_root_dir: String::new(),
        })
        .expect("offline build should succeed");

        let master_text = read_text(Path::new(&build.master_playlist_path));
        assert!(master_text.contains("CODECS=\"hvc1.2.20000000.L153.90,mp4a.40.2\""));
        assert!(master_text.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.09/db4h\""));
        assert!(master_text.contains("VIDEO-RANGE=HLG"));
        assert!(read_text(Path::new(&build.video_playlist_path)).contains("#EXT-X-TARGETDURATION:6"));

        cleanup_dir(Path::new(&build.workspace_root_dir));
        cleanup_dir(&diagnostics_dir);
    }

    #[test]
    fn offline_build_authors_local_hls_workspace_for_remux_diagnostics() {
        let diagnostics_dir = make_temp_dir("remux-build");
        write_file(&diagnostics_dir.join("metadata.json"), b"{}");
        write_file(&diagnostics_dir.join("init.mp4"), b"video-init");
        write_file(&diagnostics_dir.join("seg-0.m4s"), b"video-seg");
        write_file(&diagnostics_dir.join("local.m3u8"), b"#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.010000,\nseg-0.m4s\n");

        let build = offline_build(OfflinePackagingRequest {
            diagnostics_dir: diagnostics_dir.display().to_string(),
            output_root_dir: String::new(),
        })
        .expect("offline build should succeed");

        assert!(build.startup_ready);
        assert_eq!(build.source_kind, "remux_diagnostics");
        assert!(!build.has_audio);
        assert_eq!(
            read_text(Path::new(&build.video_playlist_path)),
            "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:11\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init-video.mp4\"\n#EXTINF:10.010000,\nv-seg-00000.m4s\n#EXT-X-ENDLIST\n"
        );
        assert!(read_text(Path::new(&build.master_playlist_path)).contains("#EXT-X-STREAM-INF:BANDWIDTH=8,AVERAGE-BANDWIDTH=8"));

        cleanup_dir(Path::new(&build.workspace_root_dir));
        cleanup_dir(&diagnostics_dir);
    }

    fn make_temp_dir(prefix: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("ibili-packaging-tests-{prefix}-{unique}"));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write_file(path: &Path, bytes: &[u8]) {
        fs::write(path, bytes).unwrap();
    }

    fn read_text(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    fn cleanup_dir(path: &Path) {
        let _ = fs::remove_dir_all(path);
    }
}