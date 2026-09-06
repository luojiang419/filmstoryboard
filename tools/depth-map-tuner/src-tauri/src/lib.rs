use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use rfd::FileDialog;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    fs,
    io::{BufRead, BufReader, Read, Write},
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, Instant},
};
use tauri::{Manager, State};
use uuid::Uuid;

const COMPONENT_ENV: &str = "SHIYIN_PERSON_DEPTH_ROOT";
const MAX_INPUT_BYTES: u64 = 150 * 1024 * 1024;
const WORKER_HELLO_TIMEOUT: Duration = Duration::from_secs(60);
const WORKER_INFERENCE_TIMEOUT: Duration = Duration::from_secs(600);

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Debug, Clone, Deserialize)]
struct CurrentComponent {
    component: String,
    version: String,
    installation: String,
    #[serde(default)]
    source_label: String,
}

#[derive(Debug, Clone, Deserialize)]
struct ComponentManifest {
    component: String,
    version: String,
    command: Vec<String>,
    #[serde(default)]
    required_paths: Vec<String>,
    #[serde(default)]
    license_notice: String,
}

#[derive(Debug, Clone)]
struct ResolvedComponent {
    component_root: PathBuf,
    installation_root: PathBuf,
    worker: PathBuf,
    version: String,
    source_label: String,
    license_notice: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ComponentStatus {
    ready: bool,
    component_root: String,
    installation_root: String,
    worker_path: String,
    version: String,
    source_label: String,
    license_notice: String,
    message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ImagePayload {
    path: String,
    name: String,
    mime: String,
    size: u64,
    data_url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DepthPayload {
    data_url: String,
    width: u32,
    height: u32,
    bit_depth: u8,
    component_version: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchContext {
    mode: String,
    mode_label: String,
    config_path: String,
}

#[derive(Debug, Clone, Default)]
struct LaunchOptions {
    mode: String,
    config_path: Option<PathBuf>,
    component_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct ToolPreferences {
    component_root: String,
}

#[derive(Clone)]
struct TunerState {
    component_root: Arc<Mutex<Option<PathBuf>>>,
    operation_lock: Arc<Mutex<()>>,
    preferences_path: PathBuf,
    mode: String,
    config_path: PathBuf,
}

impl TunerState {
    fn new(config_root: PathBuf, options: LaunchOptions) -> Self {
        let preferences_path = config_root.join("preferences.json");
        let saved_root = fs::read_to_string(&preferences_path)
            .ok()
            .and_then(|raw| serde_json::from_str::<ToolPreferences>(&raw).ok())
            .map(|value| value.component_root.trim().to_string())
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let component_root = options.component_root.or(saved_root);
        Self {
            component_root: Arc::new(Mutex::new(component_root)),
            operation_lock: Arc::new(Mutex::new(())),
            preferences_path,
            mode: normalize_mode(&options.mode).to_string(),
            config_path: options
                .config_path
                .unwrap_or_else(|| config_root.join("depth-map-config.json")),
        }
    }

    fn save_component_root(&self, root: &Path) -> Result<(), String> {
        let parent = self
            .preferences_path
            .parent()
            .ok_or_else(|| "无法定位调参器配置目录".to_string())?;
        fs::create_dir_all(parent).map_err(|error| format!("无法创建调参器配置目录：{error}"))?;
        let content = serde_json::to_string_pretty(&ToolPreferences {
            component_root: root.display().to_string(),
        })
        .map_err(|error| format!("无法序列化调参器配置：{error}"))?;
        fs::write(&self.preferences_path, format!("{content}\n"))
            .map_err(|error| format!("无法保存调参器配置：{error}"))
    }

    fn set_component_root(
        &self,
        root: PathBuf,
        persist: bool,
    ) -> Result<ResolvedComponent, String> {
        let resolved = resolve_component_root(&root)?;
        *self
            .component_root
            .lock()
            .map_err(|_| "共享组件状态锁已损坏".to_string())? =
            Some(resolved.component_root.clone());
        if persist {
            self.save_component_root(&resolved.component_root)?;
        }
        Ok(resolved)
    }

    fn resolve(&self) -> Result<ResolvedComponent, String> {
        if let Some(root) = self
            .component_root
            .lock()
            .map_err(|_| "共享组件状态锁已损坏".to_string())?
            .clone()
        {
            if let Ok(component) = resolve_component_root(&root) {
                return Ok(component);
            }
        }
        for candidate in component_candidates() {
            if let Ok(component) = resolve_component_root(&candidate) {
                *self
                    .component_root
                    .lock()
                    .map_err(|_| "共享组件状态锁已损坏".to_string())? =
                    Some(component.component_root.clone());
                return Ok(component);
            }
        }
        Err("未找到已安装的 person-depth 组件，请点击“重新定位”选择 data/system/components/person-depth".to_string())
    }
}

fn normalize_mode(value: &str) -> &'static str {
    if value.trim().eq_ignore_ascii_case("professional")
        || value.trim().eq_ignore_ascii_case("scene")
    {
        "professional"
    } else {
        "person"
    }
}

fn worker_subject(mode: &str) -> &'static str {
    if normalize_mode(mode) == "professional" {
        "scene"
    } else {
        "person"
    }
}

fn parse_launch_options() -> LaunchOptions {
    let mut options = LaunchOptions::default();
    let mut args = std::env::args().skip(1);
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--mode" => options.mode = args.next().unwrap_or_default(),
            "--config-path" => options.config_path = args.next().map(PathBuf::from),
            "--component-root" => options.component_root = args.next().map(PathBuf::from),
            _ => {}
        }
    }
    options
}

fn is_safe_relative_path(value: &str) -> bool {
    let path = Path::new(value);
    !value.trim().is_empty()
        && !path.is_absolute()
        && path
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path, label: &str) -> Result<T, String> {
    let raw = fs::read_to_string(path).map_err(|error| format!("无法读取{label}：{error}"))?;
    serde_json::from_str(&raw).map_err(|error| format!("{label}格式错误：{error}"))
}

fn canonical_file(root: &Path, relative: &str, label: &str) -> Result<PathBuf, String> {
    if !is_safe_relative_path(relative) {
        return Err(format!("{label}包含不安全路径：{relative}"));
    }
    let root = root
        .canonicalize()
        .map_err(|error| format!("无法解析组件安装目录：{error}"))?;
    let candidate = root.join(relative);
    if !candidate.is_file() {
        return Err(format!("{label}不存在：{}", candidate.display()));
    }
    let candidate = candidate
        .canonicalize()
        .map_err(|error| format!("无法解析{label}：{error}"))?;
    if !candidate.starts_with(&root) {
        return Err(format!("{label}路径越界"));
    }
    Ok(candidate)
}

fn resolve_component_root(selected: &Path) -> Result<ResolvedComponent, String> {
    let selected = selected
        .canonicalize()
        .map_err(|error| format!("共享组件目录不可用：{error}"))?;

    if selected.join("current.json").is_file() && selected.join("manifest.json").is_file() {
        let current: CurrentComponent = read_json(&selected.join("current.json"), "current.json")?;
        let manifest: ComponentManifest =
            read_json(&selected.join("manifest.json"), "manifest.json")?;
        if current.component != "person-depth" || manifest.component != "person-depth" {
            return Err("所选目录不是 person-depth 组件".to_string());
        }
        if current.version.trim().is_empty() || current.version != manifest.version {
            return Err("共享组件的 current.json 与 manifest.json 版本不一致".to_string());
        }
        if !is_safe_relative_path(&current.installation)
            || Path::new(&current.installation).components().count() != 1
        {
            return Err("current.json installation 路径无效".to_string());
        }
        let installations = selected.join("installations");
        let installation_root = installations
            .join(&current.installation)
            .canonicalize()
            .map_err(|error| format!("当前组件安装目录不可用：{error}"))?;
        let installations = installations
            .canonicalize()
            .map_err(|error| format!("组件 installations 目录不可用：{error}"))?;
        if !installation_root.starts_with(&installations) {
            return Err("当前组件安装目录路径越界".to_string());
        }
        let command = manifest
            .command
            .first()
            .ok_or_else(|| "manifest.json 缺少 worker command".to_string())?;
        let worker = canonical_file(&installation_root, command, "worker")?;
        for required in &manifest.required_paths {
            canonical_file(&installation_root, required, "组件必要文件")?;
        }
        return Ok(ResolvedComponent {
            component_root: selected,
            installation_root,
            worker,
            version: current.version,
            source_label: current.source_label,
            license_notice: manifest.license_notice,
        });
    }

    let worker_relative = "runtime/person-depth-worker.exe";
    if selected.join(worker_relative).is_file() && selected.join("models").is_dir() {
        let component_info: Value = fs::read_to_string(selected.join("component-manifest.json"))
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_else(|| json!({}));
        return Ok(ResolvedComponent {
            component_root: selected.clone(),
            installation_root: selected.clone(),
            worker: canonical_file(&selected, worker_relative, "worker")?,
            version: component_info
                .get("version")
                .and_then(Value::as_str)
                .unwrap_or("未知版本")
                .to_string(),
            source_label: "手动选择的组件安装目录".to_string(),
            license_notice: "Depth Anything V2 Large: CC-BY-NC-4.0; BiRefNet: MIT".to_string(),
        });
    }

    Err("所选目录不包含有效的 person-depth 当前组件或安装目录".to_string())
}

fn push_ancestor_candidates(candidates: &mut Vec<PathBuf>, start: &Path) {
    for ancestor in start.ancestors().take(10) {
        candidates.push(ancestor.join("data/system/components/person-depth"));
        candidates.push(ancestor.join("app/data/system/components/person-depth"));
    }
}

fn component_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(value) = std::env::var(COMPONENT_ENV) {
        if !value.trim().is_empty() {
            candidates.push(PathBuf::from(value.trim()));
        }
    }
    // 优先复用正式安装版组件，避免源码目录中的本机候选包抢占选择。
    candidates.push(PathBuf::from(
        r"D:\Program Files\SHIYIN AI\data\system\components\person-depth",
    ));
    candidates.push(PathBuf::from(
        r"C:\Program Files\SHIYIN AI\data\system\components\person-depth",
    ));
    if let Ok(executable) = std::env::current_exe() {
        push_ancestor_candidates(&mut candidates, &executable);
    }
    if let Ok(current) = std::env::current_dir() {
        push_ancestor_candidates(&mut candidates, &current);
    }
    push_ancestor_candidates(&mut candidates, Path::new(env!("CARGO_MANIFEST_DIR")));
    let mut seen = HashSet::new();
    candidates
        .into_iter()
        .filter(|path| seen.insert(path.clone()))
        .collect()
}

fn component_status(component: Result<ResolvedComponent, String>) -> ComponentStatus {
    match component {
        Ok(value) => ComponentStatus {
            ready: true,
            component_root: value.component_root.display().to_string(),
            installation_root: value.installation_root.display().to_string(),
            worker_path: value.worker.display().to_string(),
            version: value.version,
            source_label: value.source_label,
            license_notice: value.license_notice,
            message: "共享高精度深度组件已就绪".to_string(),
        },
        Err(error) => ComponentStatus {
            ready: false,
            component_root: String::new(),
            installation_root: String::new(),
            worker_path: String::new(),
            version: String::new(),
            source_label: String::new(),
            license_notice: "Depth Anything V2 Large: CC-BY-NC-4.0; BiRefNet: MIT".to_string(),
            message: error,
        },
    }
}

fn image_mime(path: &Path) -> Result<&'static str, String> {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "png" => Ok("image/png"),
        "jpg" | "jpeg" | "jfif" => Ok("image/jpeg"),
        "webp" => Ok("image/webp"),
        "bmp" => Ok("image/bmp"),
        _ => Err("仅支持 PNG、JPG、JPEG、WEBP 或 BMP 图片".to_string()),
    }
}

fn load_image_payload(path: &Path) -> Result<ImagePayload, String> {
    if !path.is_file() {
        return Err("输入图片不存在".to_string());
    }
    let mime = image_mime(path)?;
    let metadata = fs::metadata(path).map_err(|error| format!("无法读取图片信息：{error}"))?;
    if metadata.len() == 0 || metadata.len() > MAX_INPUT_BYTES {
        return Err("输入图片必须大于 0 且不超过 150MB".to_string());
    }
    let content = fs::read(path).map_err(|error| format!("无法读取输入图片：{error}"))?;
    Ok(ImagePayload {
        path: path.display().to_string(),
        name: path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("input-image")
            .to_string(),
        mime: mime.to_string(),
        size: metadata.len(),
        data_url: format!("data:{mime};base64,{}", BASE64.encode(content)),
    })
}

fn spawn_response_reader(stdout: impl Read + Send + 'static) -> mpsc::Receiver<Value> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines().map_while(Result::ok) {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if sender.send(value).is_err() {
                    break;
                }
            }
        }
    });
    receiver
}

fn protocol_request(
    stdin: &mut impl Write,
    responses: &mpsc::Receiver<Value>,
    payload: Value,
    timeout: Duration,
) -> Result<Value, String> {
    let request_id = payload
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    serde_json::to_writer(&mut *stdin, &payload)
        .map_err(|error| format!("无法写入 worker 请求：{error}"))?;
    stdin
        .write_all(b"\n")
        .and_then(|_| stdin.flush())
        .map_err(|error| format!("无法发送 worker 请求：{error}"))?;
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("共享深度 worker 响应超时".to_string());
        }
        let response = responses
            .recv_timeout(remaining)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => "共享深度 worker 响应超时".to_string(),
                mpsc::RecvTimeoutError::Disconnected => "worker 在返回结果前意外退出".to_string(),
            })?;
        if response.get("id").and_then(Value::as_str) != Some(request_id.as_str()) {
            continue;
        }
        if !response.get("ok").and_then(Value::as_bool).unwrap_or(false) {
            return Err(response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("高精度人物深度推理失败")
                .to_string());
        }
        return Ok(response);
    }
}

fn infer_depth(
    component: &ResolvedComponent,
    input: &Path,
    subject: &str,
) -> Result<DepthPayload, String> {
    if !input.is_file() {
        return Err("输入图片不存在".to_string());
    }
    image_mime(input)?;
    let temporary_root =
        std::env::temp_dir().join(format!("shiyin-depth-tuner-{}", Uuid::new_v4()));
    fs::create_dir_all(&temporary_root).map_err(|error| format!("无法创建临时目录：{error}"))?;
    // Packaged Python/Pillow 在部分 Windows 中文或网络路径上会误报文件不存在。
    // 与主应用保持一致，将输入复制到纯 ASCII 临时路径后再交给共享 worker。
    let worker_input = temporary_root.join("input.png");
    let output = temporary_root.join("depth.png");
    let mut command = Command::new(&component.worker);
    command
        .arg("--stdio")
        .arg("--component-root")
        .arg(&component.installation_root)
        .current_dir(&component.installation_root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("PYTHONUTF8", "1")
        .env("PYTHONIOENCODING", "utf-8");
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);
    let result = (|| {
        fs::copy(input, &worker_input)
            .map_err(|error| format!("无法准备深度推理临时输入：{error}"))?;
        let mut child = command
            .spawn()
            .map_err(|error| format!("无法启动共享深度 worker：{error}"))?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "无法连接 worker 输入".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "无法连接 worker 输出".to_string())?;
        let responses = spawn_response_reader(stdout);
        let hello_id = Uuid::new_v4().to_string();
        let hello = match protocol_request(
            &mut stdin,
            &responses,
            json!({"id": hello_id, "op": "hello"}),
            WORKER_HELLO_TIMEOUT,
        ) {
            Ok(value) => value,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        if hello.get("protocol_version").and_then(Value::as_u64) != Some(1) {
            let _ = child.kill();
            return Err("共享深度 worker 协议版本不匹配".to_string());
        }
        let estimate_id = Uuid::new_v4().to_string();
        let response = protocol_request(
            &mut stdin,
            &responses,
            json!({
                "id": estimate_id,
                "op": "estimate",
                "input": worker_input.display().to_string(),
                "output": output.display().to_string(),
                "bit_depth": 8,
                "subject": subject
            }),
            WORKER_INFERENCE_TIMEOUT,
        );
        if response.is_ok() {
            let _ = writeln!(stdin, "{}", json!({"op": "shutdown"}));
            let _ = stdin.flush();
        } else {
            let _ = child.kill();
        }
        let _ = child.wait();
        let mut stderr = String::new();
        if let Some(mut stream) = child.stderr.take() {
            let _ = stream.read_to_string(&mut stderr);
        }
        let response = response.map_err(|error| {
            let detail = stderr
                .lines()
                .rev()
                .take(6)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join(" | ");
            if detail.is_empty() {
                error
            } else {
                format!("{error}：{detail}")
            }
        })?;
        if !output.is_file() {
            return Err("共享深度 worker 未生成输出文件".to_string());
        }
        let content = fs::read(&output).map_err(|error| format!("无法读取深度图：{error}"))?;
        if content.is_empty() {
            return Err("共享深度 worker 输出为空".to_string());
        }
        Ok(DepthPayload {
            data_url: format!("data:image/png;base64,{}", BASE64.encode(content)),
            width: response.get("width").and_then(Value::as_u64).unwrap_or(0) as u32,
            height: response.get("height").and_then(Value::as_u64).unwrap_or(0) as u32,
            bit_depth: response
                .get("bit_depth")
                .and_then(Value::as_u64)
                .unwrap_or(8) as u8,
            component_version: component.version.clone(),
        })
    })();
    let _ = fs::remove_dir_all(&temporary_root);
    result
}

fn decode_png_data_url(data_url: &str) -> Result<Vec<u8>, String> {
    let encoded = data_url
        .strip_prefix("data:image/png;base64,")
        .ok_or_else(|| "导出数据不是 PNG data URL".to_string())?;
    BASE64
        .decode(encoded)
        .map_err(|error| format!("PNG 数据解码失败：{error}"))
}

fn clean_suggested_name(value: &str, fallback: &str, extension: &str) -> String {
    let name: String = value
        .chars()
        .map(|character| {
            if character.is_control()
                || matches!(
                    character,
                    '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|'
                )
            {
                '_'
            } else {
                character
            }
        })
        .collect();
    let name = name.trim().trim_end_matches(['.', ' ']);
    let mut result = if name.is_empty() {
        fallback.to_string()
    } else {
        name.to_string()
    };
    if !result.to_ascii_lowercase().ends_with(extension) {
        result.push_str(extension);
    }
    result
}

#[tauri::command]
fn get_component_status(state: State<'_, TunerState>) -> ComponentStatus {
    component_status(state.resolve())
}

#[tauri::command]
fn get_launch_context(state: State<'_, TunerState>) -> LaunchContext {
    LaunchContext {
        mode: state.mode.clone(),
        mode_label: if state.mode == "professional" {
            "专业模式".to_string()
        } else {
            "人物模式".to_string()
        },
        config_path: state.config_path.display().to_string(),
    }
}

#[tauri::command]
fn choose_component_root(state: State<'_, TunerState>) -> Result<Option<ComponentStatus>, String> {
    let Some(path) = FileDialog::new()
        .set_title("选择 person-depth 组件目录")
        .pick_folder()
    else {
        return Ok(None);
    };
    let component = state.set_component_root(path, true)?;
    Ok(Some(component_status(Ok(component))))
}

#[tauri::command]
fn choose_input_image() -> Result<Option<ImagePayload>, String> {
    let Some(path) = FileDialog::new()
        .set_title("选择输入图片")
        .add_filter("图片", &["png", "jpg", "jpeg", "jfif", "webp", "bmp"])
        .pick_file()
    else {
        return Ok(None);
    };
    load_image_payload(&path).map(Some)
}

#[tauri::command]
fn load_input_image(path: String) -> Result<ImagePayload, String> {
    load_image_payload(Path::new(path.trim()))
}

#[tauri::command]
async fn generate_depth(
    state: State<'_, TunerState>,
    input_path: String,
    mode: String,
) -> Result<DepthPayload, String> {
    let snapshot = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = snapshot
            .operation_lock
            .lock()
            .map_err(|_| "推理任务锁已损坏".to_string())?;
        let component = snapshot.resolve()?;
        infer_depth(
            &component,
            Path::new(input_path.trim()),
            worker_subject(&mode),
        )
    })
    .await
    .map_err(|error| format!("推理后台任务失败：{error}"))?
}

#[tauri::command]
fn export_depth_png(data_url: String, suggested_name: String) -> Result<Option<String>, String> {
    let content = decode_png_data_url(&data_url)?;
    let filename = clean_suggested_name(&suggested_name, "depth-map", ".png");
    let Some(path) = FileDialog::new()
        .set_title("导出深度图")
        .set_file_name(&filename)
        .add_filter("PNG 深度图", &["png"])
        .save_file()
    else {
        return Ok(None);
    };
    fs::write(&path, content).map_err(|error| format!("深度图保存失败：{error}"))?;
    Ok(Some(path.display().to_string()))
}

#[tauri::command]
fn load_parameter_config(state: State<'_, TunerState>) -> Result<Option<Value>, String> {
    load_parameter_profile(&state.config_path, &state.mode)
}

fn load_parameter_profile(path: &Path, mode: &str) -> Result<Option<Value>, String> {
    if !path.is_file() {
        return Ok(None);
    }
    let content =
        fs::read_to_string(path).map_err(|error| format!("无法读取共享参数配置：{error}"))?;
    let value: Value = serde_json::from_str(&content)
        .map_err(|error| format!("共享参数配置 JSON 无效：{error}"))?;
    Ok(value
        .get("profiles")
        .and_then(|profiles| profiles.get(normalize_mode(mode)))
        .cloned())
}

#[tauri::command]
fn save_parameter_config(state: State<'_, TunerState>, controls: Value) -> Result<String, String> {
    save_parameter_profile(&state.config_path, &state.mode, controls)?;
    Ok(state.config_path.display().to_string())
}

fn save_parameter_profile(path: &Path, mode: &str, controls: Value) -> Result<(), String> {
    if !controls.is_object() {
        return Err("参数配置必须是 JSON 对象".to_string());
    }
    let mut value: Value = fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| {
            json!({
                "schema": "filmstoryboard.depth-map-config/v1",
                "schemaVersion": 1,
                "profiles": {}
            })
        });
    let object = value
        .as_object_mut()
        .ok_or_else(|| "共享参数配置根节点无效".to_string())?;
    object.insert(
        "schema".to_string(),
        Value::String("filmstoryboard.depth-map-config/v1".to_string()),
    );
    object.insert("schemaVersion".to_string(), Value::from(1));
    let profiles = object
        .entry("profiles".to_string())
        .or_insert_with(|| json!({}));
    if !profiles.is_object() {
        *profiles = json!({});
    }
    profiles
        .as_object_mut()
        .expect("profiles was normalized to an object")
        .insert(normalize_mode(mode).to_string(), controls);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("无法创建共享配置目录：{error}"))?;
    }
    let content = serde_json::to_string_pretty(&value)
        .map_err(|error| format!("无法序列化共享参数配置：{error}"))?;
    fs::write(path, format!("{content}\n"))
        .map_err(|error| format!("参数配置保存失败：{error}"))?;
    Ok(())
}

pub fn run() {
    let launch_options = parse_launch_options();
    tauri::Builder::default()
        .setup(move |app| {
            let config_root = app
                .path()
                .app_config_dir()
                .map_err(|error| format!("无法定位调参器配置目录：{error}"))?;
            app.manage(TunerState::new(config_root, launch_options.clone()));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_component_status,
            get_launch_context,
            choose_component_root,
            choose_input_image,
            load_input_image,
            generate_depth,
            export_depth_png,
            load_parameter_config,
            save_parameter_config
        ])
        .run(tauri::generate_context!())
        .expect("filmstoryboard 深度图调参器启动失败");
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn write_valid_component(root: &Path) -> PathBuf {
        let install = root.join("installations/v1-active");
        fs::create_dir_all(install.join("runtime")).unwrap();
        fs::create_dir_all(install.join("models/depth-anything-v2-large")).unwrap();
        fs::write(install.join("runtime/person-depth-worker.exe"), b"worker").unwrap();
        fs::write(
            install.join("models/depth-anything-v2-large/config.json"),
            b"{}",
        )
        .unwrap();
        fs::write(
            root.join("current.json"),
            r#"{"component":"person-depth","version":"1.2.3","installation":"v1-active","source_label":"test"}"#,
        )
        .unwrap();
        fs::write(
            root.join("manifest.json"),
            r#"{"component":"person-depth","version":"1.2.3","command":["runtime/person-depth-worker.exe"],"required_paths":["runtime/person-depth-worker.exe","models/depth-anything-v2-large/config.json"],"license_notice":"test license"}"#,
        )
        .unwrap();
        install
    }

    #[test]
    fn resolves_active_shared_component_without_copying_it() {
        let temp = tempdir().unwrap();
        let expected = write_valid_component(temp.path());
        let resolved = resolve_component_root(temp.path()).unwrap();
        assert_eq!(resolved.version, "1.2.3");
        assert_eq!(resolved.installation_root, expected.canonicalize().unwrap());
        assert!(resolved.worker.ends_with("runtime/person-depth-worker.exe"));
    }

    #[test]
    fn rejects_component_path_traversal() {
        let temp = tempdir().unwrap();
        write_valid_component(temp.path());
        fs::write(
            temp.path().join("current.json"),
            r#"{"component":"person-depth","version":"1.2.3","installation":"../outside","source_label":"test"}"#,
        )
        .unwrap();
        assert!(resolve_component_root(temp.path()).is_err());
        assert!(!is_safe_relative_path("../worker.exe"));
        assert!(!is_safe_relative_path("/worker.exe"));
    }

    #[test]
    fn png_data_url_round_trip_and_filename_cleanup() {
        let data = b"png-data";
        let url = format!("data:image/png;base64,{}", BASE64.encode(data));
        assert_eq!(decode_png_data_url(&url).unwrap(), data);
        assert_eq!(
            clean_suggested_name("bad:name", "fallback", ".png"),
            "bad_name.png"
        );
    }

    #[test]
    fn shared_profiles_are_saved_independently() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("depth-map-config.json");
        save_parameter_profile(&path, "person", json!({"contrast": 122})).unwrap();
        save_parameter_profile(&path, "professional", json!({"contrast": 88, "smooth": 4}))
            .unwrap();
        assert_eq!(
            load_parameter_profile(&path, "person").unwrap(),
            Some(json!({"contrast": 122}))
        );
        assert_eq!(
            load_parameter_profile(&path, "scene").unwrap(),
            Some(json!({"contrast": 88, "smooth": 4}))
        );
    }

    #[test]
    #[ignore = "requires the locally installed 5.98GB person-depth component and a smoke image"]
    fn real_shared_component_inference() {
        let image = std::env::var("SHIYIN_DEPTH_TUNER_SMOKE_IMAGE")
            .expect("set SHIYIN_DEPTH_TUNER_SMOKE_IMAGE to a local PNG/JPG/WEBP/BMP");
        let component = component_candidates()
            .into_iter()
            .find_map(|candidate| resolve_component_root(&candidate).ok())
            .expect("installed person-depth component was not found");
        let result = infer_depth(&component, Path::new(&image), "person").unwrap();
        assert_eq!(result.bit_depth, 8);
        assert!(result.width > 0 && result.height > 0);
        assert!(result.data_url.starts_with("data:image/png;base64,"));
        assert_eq!(result.component_version, component.version);
    }
}
