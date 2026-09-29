// Shared property inspector logic.
//
// Form fields with `data-setting="key"` are bound to the action's settings (`data-default` supplies the initial value,
// `data-default-encoder` overrides it for dials).
// Elements with `data-show="key=a,b"` are only visible when that setting has one of the listed values, and
// `data-controller="Encoder|Keypad"` only for that controller type. Pages may define `onPluginMessage(payload)`
// and `onConnected()` hooks.

let socket;
let actionInfo;
let settings = {};

function connectElgatoStreamDeckSocket(port, uuid, registerEvent, info, actionInfoJson) {
	actionInfo = JSON.parse(actionInfoJson);
	settings = actionInfo.payload.settings || {};
	socket = new WebSocket("ws://localhost:" + port);
	socket.onopen = () => {
		socket.send(JSON.stringify({ event: registerEvent, uuid }));
		if (typeof onConnected === "function") onConnected();
	};
	socket.onmessage = (message) => {
		const data = JSON.parse(message.data);
		if (data.event === "sendToPropertyInspector" && typeof onPluginMessage === "function") onPluginMessage(data.payload);
		if (data.event === "didReceiveSettings") {
			settings = data.payload.settings || {};
			load();
		}
	};
	document.body.dataset.action = actionInfo.action.split(".").pop();
	load();
}

function fields() {
	return document.querySelectorAll("[data-setting]");
}

function load() {
	for (const field of fields()) {
		const key = field.dataset.setting;
		const value = key in settings ? settings[key] : parse(field, defaultFor(field));
		if (field.type === "checkbox") field.checked = Boolean(value);
		else if (field.tagName === "SELECT" && value !== "" && ![...field.options].some((o) => o.value === String(value))) {
			// Keep values that are not (yet) in the list, e.g. a shortcut that was renamed.
			field.add(new Option(value, value));
			field.value = String(value);
		} else field.value = value;
		field.oninput = save;
		field.onchange = save;
	}
	refreshVisibility();
}

function defaultFor(field) {
	if (actionInfo.payload.controller === "Encoder" && field.dataset.defaultEncoder !== undefined) return field.dataset.defaultEncoder;
	return field.dataset.default ?? "";
}

function parse(field, raw) {
	if (field.type === "checkbox") return raw === true || raw === "true";
	if (field.type === "number" || field.type === "range") return raw === "" ? "" : Number(raw);
	return raw;
}

function save() {
	for (const field of fields()) {
		const key = field.dataset.setting;
		settings[key] = field.type === "checkbox" ? field.checked : parse(field, field.value);
	}
	socket.send(JSON.stringify({ event: "setSettings", context: actionInfo.context, payload: settings }));
	refreshVisibility();
}

function sendToPlugin(payload) {
	socket.send(JSON.stringify({ event: "sendToPlugin", action: actionInfo.action, context: actionInfo.context, payload }));
}

function current(key) {
	if (key in settings) return String(settings[key]);
	const field = document.querySelector(`[data-setting="${key}"]`);
	return field ? String(defaultFor(field)) : "";
}

function refreshVisibility() {
	for (const element of document.querySelectorAll("[data-show]")) {
		const [key, values] = element.dataset.show.split("=");
		element.hidden = !values.split(",").includes(current(key));
	}
	for (const element of document.querySelectorAll("[data-controller]")) {
		element.hidden = element.dataset.controller !== actionInfo.payload.controller;
	}
	for (const element of document.querySelectorAll("[data-for-action]")) {
		element.hidden = !element.dataset.forAction.split(",").includes(document.body.dataset.action);
	}
}
