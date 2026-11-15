import "./globals.css";
import EnvBadge from "./EnvBadge";

export const metadata = { title: "StockMarket · Dow Scanner" };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <EnvBadge />
        {children}
      </body>
    </html>
  );
}
