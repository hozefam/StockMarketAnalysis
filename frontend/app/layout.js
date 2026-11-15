import "./globals.css";

export const metadata = { title: "StockMarket · Dow Scanner" };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
