const segments = Array.from(document.querySelectorAll(".segment"));
const panels = {
  mac: document.querySelector("#mac-panel"),
  android: document.querySelector("#android-panel")
};

function setDevice(device) {
  for (const segment of segments) {
    const active = segment.dataset.device === device;
    segment.classList.toggle("active", active);
    segment.setAttribute("aria-selected", String(active));
  }
  for (const [name, panel] of Object.entries(panels)) {
    panel.classList.toggle("hidden", name !== device);
  }
}

segments.forEach((segment) => {
  segment.addEventListener("click", () => setDevice(segment.dataset.device));
});

const ua = navigator.userAgent.toLowerCase();
if (ua.includes("android")) {
  setDevice("android");
}
