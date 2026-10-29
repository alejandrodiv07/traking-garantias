import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import Login from "./Login.jsx";

/**
 * Contrato del paso 1 ante un rechazo de `onSubmit`:
 *
 * El mensaje que muestra la tarjeta NO lo fabrica aquí: viene ya colapsado
 * por `authService` / `LoginPage`. Lo que exige este test es que `Login` lo
 * muestre TAL CUAL en lugar de descartarlo y endurecerlo a
 * "Credenciales incorrectas" — bug real del 29/10/2026: un 502 de
 * `mfa-enviar-codigo` (Resend caído) se pintaba como contraseña mala.
 *
 * El colapso anti-enumeración para credenciales malas sigue vivo: lo aplica
 * `authService.iniciarSesion` ANTES de que cualquier texto llegue aquí.
 */

/** Rellena el paso 1 con valores válidos y lo envía. */
async function enviarFormulario() {
  const usuario = userEvent.setup();
  await usuario.type(screen.getByLabelText("Correo corporativo"), "j.rivera@primetelecom.com");
  await usuario.type(screen.getByLabelText(/Contraseña/), "secreta");
  await usuario.click(screen.getByRole("button", { name: "Ingresar" }));
}

describe("Login · paso 1 · mensaje de error", () => {
  it("muestra el mensaje real cuando falla el envío del código (no 'Credenciales incorrectas')", async () => {
    render(<Login onSubmit={() => Promise.reject(new Error("No se pudo enviar el código de verificación."))} />);

    await enviarFormulario();

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "No se pudo enviar el código de verificación."
    );
    // El engaño era el bug: la contraseña era correcta.
    expect(screen.queryByText("Credenciales incorrectas")).not.toBeInTheDocument();
    // El cuerpo genérico ya no describe el rechazo con un mensaje propio.
    expect(screen.queryByText("No indicamos cuál de los dos falló.")).not.toBeInTheDocument();
  });

  it("mantiene el mensaje colapsado cuando el rechazo son credenciales malas", async () => {
    render(<Login onSubmit={() => Promise.reject(new Error("Credenciales incorrectas"))} />);

    await enviarFormulario();

    const alerta = await screen.findByRole("alert");
    expect(alerta).toHaveTextContent("Credenciales incorrectas");
    expect(alerta).toHaveTextContent("No indicamos cuál de los dos falló.");
  });

  it("recurre al mensaje genérico si el rechazo llega sin texto", async () => {
    render(<Login onSubmit={() => Promise.reject(new Error("   "))} />);

    await enviarFormulario();

    expect(await screen.findByText("Credenciales incorrectas")).toBeInTheDocument();
  });
});