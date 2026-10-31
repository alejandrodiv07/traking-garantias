// Tema claro/oscuro. Oscuro por defecto (decisión actual); la elección se guarda.
const CLAVE = "pt.tema";

export function temaGuardado() {
  try {
    const t = localStorage.getItem(CLAVE);
    if (t === "light" || t === "dark") return t;
  } catch {
    // sin almacenamiento: queda el predeterminado
  }
  return "dark";
}

export function aplicarTema(t) {
  document.documentElement.dataset.theme = t;
  try {
    localStorage.setItem(CLAVE, t);
  } catch {
    // modo privado: el tema vale solo para esta visita
  }
}
