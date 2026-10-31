// CSV de Ventas en el navegador, sin dependencias. El servidor (importar_ventas)
// vuelve a validar cada fila: esto solo da la vista previa y arma el JSON.

/** Filas de celdas. Delimitador `;` o `,` (el que más aparezca en la primera línea). */
export function parseCsv(texto) {
  const t = String(texto ?? "").replace(/^﻿/, "");
  const primera = t.split(/\r?\n/, 1)[0];
  const d = (primera.match(/;/g) ?? []).length > (primera.match(/,/g) ?? []).length ? ";" : ",";

  const filas = [];
  let fila = [];
  let celda = "";
  let entre = false;
  const cerrarFila = () => {
    fila.push(celda);
    celda = "";
    if (fila.some((c) => c.trim() !== "")) filas.push(fila);
    fila = [];
  };

  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (entre) {
      if (c === '"' && t[i + 1] === '"') {
        celda += '"';
        i++;
      } else if (c === '"') entre = false;
      else celda += c;
    } else if (c === '"') entre = true;
    else if (c === d) {
      fila.push(celda);
      celda = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && t[i + 1] === "\n") i++;
      cerrarFila();
    } else celda += c;
  }
  if (celda !== "" || fila.length) cerrarFila();
  return filas;
}

const OBLIGATORIAS = ["numero_factura", "fecha_emision", "numero_documento", "serial"];
const OPCIONALES = ["tipo_documento", "nombre_cliente", "modelo", "vendedor"];

const clave = (s) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");

/** `YYYY-MM-DD` o `DD/MM/AAAA` → ISO; null si no es una fecha real. */
function fechaIso(s) {
  let a, m, d;
  let r = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (r) [, a, m, d] = r;
  else if ((r = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s))) [, d, m, a] = r;
  else return null;
  const iso = `${a}-${m.padStart(2, "0")}-${d.padStart(2, "0")}`;
  const f = new Date(`${iso}T00:00:00Z`);
  return !Number.isNaN(f.getTime()) && f.toISOString().slice(0, 10) === iso ? iso : null;
}

const entre = (s, min, max) => s.length >= min && s.length <= max;

/** Mismas reglas que la RPC, para marcar en la vista previa lo que va a fallar. */
function validar(d, hoy) {
  if (!entre(d.numero_factura, 1, 40)) return { campo: "numero_factura", mensaje: "La factura es obligatoria (hasta 40 caracteres)" };
  const f = fechaIso(d.fecha_emision);
  if (!f) return { campo: "fecha_emision", mensaje: "Fecha ilegible: use AAAA-MM-DD o DD/MM/AAAA" };
  if (f < "2000-01-01" || f > hoy) return { campo: "fecha_emision", mensaje: "La fecha no puede ser futura ni anterior a 2000" };
  d.fecha_emision = f;
  if (!entre(d.numero_documento, 1, 30)) return { campo: "numero_documento", mensaje: "El documento es obligatorio (hasta 30 caracteres)" };
  if (!entre(d.serial, 3, 60)) return { campo: "serial", mensaje: "El serial es obligatorio (3 a 60 caracteres)" };
  return null;
}

/**
 * Texto del CSV → { faltantes, filas: [{ linea, datos, error }] }.
 * `datos` es el objeto de `importar_ventas` (null si la fila es inválida);
 * `linea` cuenta desde 1 sobre las filas no vacías (la cabecera es la 1).
 */
export function filasDeVentas(texto, hoy = new Date().toLocaleDateString("sv")) {
  const [cab = [], ...cuerpo] = parseCsv(texto);
  const col = {};
  cab.forEach((h, i) => {
    const k = clave(h);
    if ([...OBLIGATORIAS, ...OPCIONALES].includes(k) && !(k in col)) col[k] = i;
  });
  const faltantes = OBLIGATORIAS.filter((k) => !(k in col));
  if (faltantes.length) return { faltantes, cabecera: cab, filas: [] };

  const filas = cuerpo.map((celdas, i) => {
    const datos = {};
    for (const k in col) datos[k] = (celdas[col[k]] ?? "").trim();
    const error = validar(datos, hoy);
    return { linea: i + 2, datos: error ? null : datos, crudo: datos, error, original: celdas };
  });
  return { faltantes, cabecera: cab, filas };
}

const celda = (v) => {
  let s = String(v ?? "");
  if (/^[=+\-@]/.test(s)) s = `'${s}`; // Excel lo leería como fórmula
  return /[",\r\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/** Cabecera + filas → texto CSV (para devolver a Ventas las filas con error). */
export function aCsv(cabecera, filas) {
  return [cabecera, ...filas].map((f) => f.map(celda).join(",")).join("\r\n");
}
