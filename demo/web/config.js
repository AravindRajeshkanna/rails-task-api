// Where the API is, and which account the sign-in form offers. This file is the only thing to change when you host the front end
// (the demo workflow writes it for you): a page that took the API address from its URL could be pointed at someone else's server
// and used to collect passwords, so it is not configurable from outside.
export const config = {
  apiUrl: "http://localhost:3000",
  // The public demo's shared account (docs/demo.md). Set to null on anything that is not a demo.
  demoLogin: { email: "demo@example.com", password: "password123" }
}
