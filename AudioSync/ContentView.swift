//
//  ContentView.swift
//  AudioSync
//
//  Created by Brian Gomberg on 10/12/21.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var audioManager = AudioManager.shared
    @State private var buttonDisabled = true

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("Audio Sync Demo App")
                .font(.title)
                .padding()
            Button(action: {
                print("Clicked button")
                guard !audioManager.isPlaying else { return }
                audioManager.start()
            }, label: {
                if self.audioManager.isPlaying {
                    Text("Running...")
                } else {
                    Text("Start")
                }
            })
            .disabled(buttonDisabled || self.audioManager.isPlaying)
            .onAppear() {
                audioManager.setup {
                    buttonDisabled = false
                }
            }
            Spacer()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
