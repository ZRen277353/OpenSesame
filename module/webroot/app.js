const CONTROL = "/data/adb/modules/opensesame/control.sh";

const state = {
	loaded: false,
	busy: false,
};

const els = {
	statePill: document.getElementById("statePill"),
	toggleBtn: document.getElementById("toggleBtn"),
	masterHint: document.getElementById("masterHint"),
	vermagicSwitch: document.getElementById("vermagicSwitch"),
	crcSwitch: document.getElementById("crcSwitch"),
	autoStartSwitch: document.getElementById("autoStartSwitch"),
	autoStartHint: document.getElementById("autoStartHint"),
	refreshLogsBtn: document.getElementById("refreshLogsBtn"),
	logBox: document.getElementById("logBox"),
	toast: document.getElementById("toast"),
};

function execShell(command) {
	return new Promise((resolve, reject) => {
		if (!window.ksu || typeof window.ksu.exec !== "function") {
			reject(new Error("当前管理器未提供 KernelSU WebUI API"));
			return;
		}

		const callback = `opensesame_cb_${Date.now()}_${Math.random().toString(16).slice(2)}`;
		window[callback] = (errno, stdout, stderr) => {
			delete window[callback];
			resolve({ errno, stdout: stdout || "", stderr: stderr || "" });
		};

		try {
			window.ksu.exec(command, "{}", callback);
		} catch (error) {
			delete window[callback];
			reject(error);
		}
	});
}

async function run(action) {
	const result = await execShell(`sh ${CONTROL} ${action}`);
	if (result.errno !== 0) {
		const message = (result.stderr || result.stdout || "命令执行失败").trim();
		throw new Error(message);
	}
	return result;
}

function parseStatus(output) {
	const data = {};
	for (const line of output.split(/\r?\n/)) {
		const index = line.indexOf("=");
		if (index > 0) {
			data[line.slice(0, index)] = line.slice(index + 1);
		}
	}
	return data;
}

function showToast(message, isError = false) {
	els.toast.textContent = message;
	els.toast.classList.toggle("error", isError);
	els.toast.classList.add("show");
	window.clearTimeout(showToast.timer);
	showToast.timer = window.setTimeout(() => {
		els.toast.classList.remove("show");
	}, isError ? 4200 : 2200);
}

function setBusy(isBusy) {
	state.busy = isBusy;
	els.toggleBtn.disabled = isBusy;
	els.vermagicSwitch.disabled = isBusy;
	els.crcSwitch.disabled = isBusy;
	els.autoStartSwitch.disabled = isBusy;
	els.refreshLogsBtn.disabled = isBusy;
}

function featureLabels(data) {
	const labels = [];
	if (data.active_vermagic === "1") {
		labels.push("vermagic");
	}
	if (data.active_crc === "1") {
		labels.push("CRC");
	}
	return labels;
}

function configuredLabels(data) {
	const labels = [];
	if (data.vermagic === "1") {
		labels.push("vermagic");
	}
	if (data.crc === "1") {
		labels.push("CRC");
	}
	return labels;
}

function applyStatus(data) {
	state.loaded = data.loaded === "1";
	const active = featureLabels(data);
	const configured = configuredLabels(data);

	els.statePill.textContent = state.loaded ? "已加载" : "未加载";
	els.statePill.classList.toggle("on", state.loaded);
	els.statePill.classList.toggle("off", !state.loaded);
	els.toggleBtn.textContent = state.loaded ? "卸载模块" : "加载模块";

	if (state.loaded) {
		els.masterHint.textContent = active.length
			? `当前生效: ${active.join(" + ")}`
			: "模块已加载，当前没有校验放行生效";
	} else if (configured.length) {
		els.masterHint.textContent = `已选择: ${configured.join(" + ")}`;
	} else {
		els.masterHint.textContent = "未启用校验放行开关";
	}

	els.vermagicSwitch.checked = data.vermagic === "1";
	els.crcSwitch.checked = data.crc === "1";
	els.autoStartSwitch.checked = data.auto_start === "1";
	els.autoStartHint.textContent = data.auto_start === "1" ? "开启" : "关闭";
}

async function refreshStatus() {
	const result = await run("status");
	applyStatus(parseStatus(result.stdout));
}

async function refreshLogs() {
	const result = await run("logs");
	els.logBox.textContent = result.stdout.trim() || "(暂无日志)";
	els.logBox.scrollTop = els.logBox.scrollHeight;
}

async function refreshAll(showError = true) {
	setBusy(true);
	try {
		await refreshStatus();
		await refreshLogs();
	} catch (error) {
		if (showError) {
			showToast(error.message, true);
		}
	} finally {
		setBusy(false);
	}
}

async function toggleModule() {
	if (state.busy) {
		return;
	}
	const action = state.loaded ? "stop" : "start";
	setBusy(true);
	try {
		const result = await run(action);
		showToast(result.stdout.trim() || (action === "start" ? "已加载" : "已卸载"));
		await refreshStatus();
		await refreshLogs();
	} catch (error) {
		showToast(error.message, true);
		await refreshStatus().catch(() => {});
		await refreshLogs().catch(() => {});
	} finally {
		setBusy(false);
	}
}

async function setFlag(key, value, element) {
	if (state.busy) {
		return;
	}
	setBusy(true);
	try {
		const result = await run(`set ${key} ${value ? "1" : "0"}`);
		showToast(result.stdout.trim() || "设置已应用");
		await refreshStatus();
		await refreshLogs();
	} catch (error) {
		element.checked = !element.checked;
		showToast(error.message, true);
		await refreshStatus().catch(() => {});
	} finally {
		setBusy(false);
	}
}

els.toggleBtn.addEventListener("click", toggleModule);
els.vermagicSwitch.addEventListener("change", (event) => {
	void setFlag("vermagic", event.target.checked, els.vermagicSwitch);
});
els.crcSwitch.addEventListener("change", (event) => {
	void setFlag("crc", event.target.checked, els.crcSwitch);
});
els.autoStartSwitch.addEventListener("change", (event) => {
	void setFlag("auto_start", event.target.checked, els.autoStartSwitch);
});
els.refreshLogsBtn.addEventListener("click", () => {
	void refreshAll();
});

document.addEventListener("visibilitychange", () => {
	if (!document.hidden) {
		void refreshAll(false);
	}
});

window.setInterval(() => {
	if (!document.hidden) {
		void refreshLogs().catch(() => {});
	}
}, 5000);

void refreshAll();
