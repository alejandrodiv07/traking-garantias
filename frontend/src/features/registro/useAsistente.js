// useAsistente — el estado y la navegación del asistente "Nuevo registro"
// (Tarea 17 del plan; spec §7.1 y §7.2). El borrador vive en borrador.js y
// se guarda en cada cambio; al abrir se OFRECE restaurarlo, no se impone.
import { useEffect, useMemo, useState } from "react";
import { guardarBorrador, leerBorrador, limpiarBorrador } from "./borrador.js";

export const PASOS_COMPLETOS = [
  "equipo",
  "cliente",
  "compra",
  "verificacion",
  "adjuntos",
  "resumen",
];

export function useAsistente(userId) {
  const [paso, setPaso] = useState(0);
  const [estado, setEstado] = useState({});
  const [borradorOfrecido, setBorradorOfrecido] = useState(null);

  // Al abrir del asistente (del usuario): el borrador se OFRECE restaurar.
  useEffect(() => {
    if (!userId) return;
    const guardado = leerBorrador(userId);
    if (guardado && Object.keys(guardado).length > 0) setBorradorOfrecido(guardado);
  }, [userId]);

  // Cada cambio se amarra al borrador (guardarBorrador descarta archivos).
  useEffect(() => {
    if (!userId) return;
    if (Object.keys(estado).length === 0) return;
    guardarBorrador(userId, estado);
  }, [estado, userId]);

  const pasos = useMemo(
    () =>
      estado.equipoReutilizado
        ? PASOS_COMPLETOS.filter((p) => p !== "compra")   // spec §7.1: no se recaptura la compra
        : PASOS_COMPLETOS,
    [estado.equipoReutilizado],
  );

  function actualizar(parcial) {
    setEstado((s) => ({ ...s, ...parcial }));
  }

  function ir(n) {
    setPaso(Math.max(0, Math.min(n, pasos.length - 1)));
  }
  function siguiente() {
    ir(paso + 1);
  }
  function atras() {
    ir(paso - 1);
  }
  function reiniciar() {
    if (userId) limpiarBorrador(userId);
    setEstado({});
    setPaso(0);
    setBorradorOfrecido(null);
  }
  function restaurar() {
    if (borradorOfrecido) {
      setEstado(borradorOfrecido);
      setBorradorOfrecido(null);
    }
  }
  function descartarBorrador() {
    if (userId) limpiarBorrador(userId);
    setBorradorOfrecido(null);
  }

  return {
    paso,
    pasos,
    pasoActual: pasos[Math.min(paso, pasos.length - 1)],
    estado,
    borradorOfrecido,
    actualizar,
    ir,
    siguiente,
    atras,
    reiniciar,
    restaurar,
    descartarBorrador,
  };
}