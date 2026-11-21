import SwiftUI

struct ContentView: View {
    @State private var isConnected = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isConnected ? "shield.fill" : "shield")
                .font(.system(size: 64))
                .foregroundColor(isConnected ? .green : .gray)

            Text("R-VPN")
                .font(.largeTitle.bold())

            Text(isConnected ? "Connected" : "Not Connected")
                .foregroundColor(isConnected ? .green : .secondary)

            Button(action: { isConnected.toggle() }) {
                Text(isConnected ? "Disconnect" : "Connect")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(isConnected ? Color.red : Color.blue)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
}
