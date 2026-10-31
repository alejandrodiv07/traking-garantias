// Respaldo de Ventas de una garantía (v_garantias.verificacion). El texto lleva
// el significado; el color solo lo refuerza. Sin dato (null) no pinta nada.
const TEXTOS = {
  COINCIDE: ["Respaldada por Ventas", "ok"],
  DIFIERE: ["No coincide: revisar", "mal"],
  SIN_VENTA: ["Factura no hallada en Ventas", "neutro"],
};

export default function InsigniaVerificacion({ valor, compacta = false }) {
  const t = TEXTOS[valor];
  if (!t) return null;
  // En tablas la insignia compite con la del estado: aquí va como texto con punto, sin píldora.
  if (compacta) {
    return (
      <span className="ven" data-t={t[1]}>
        <i />
        {t[0]}
      </span>
    );
  }
  return (
    <span className="ins" data-t={t[1]}>
      <i />
      {t[0]}
    </span>
  );
}
