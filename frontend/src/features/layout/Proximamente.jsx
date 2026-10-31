// Destinos del diseño que todavía no tienen backend (Entregas, Inventario,
// Reportes, Clientes, Notificaciones): la barra los muestra y aquí se explica.
import { Construction } from "lucide-react";

export default function Proximamente({ titulo, motivo }) {
  return (
    <section>
      <div className="enc">
        <h1>{titulo}</h1>
      </div>
      <div className="card vacio">
        <Construction size={34} strokeWidth={1.6} aria-hidden="true" />
        <h3>Pantalla en preparación</h3>
        <p>{motivo}</p>
      </div>
    </section>
  );
}
