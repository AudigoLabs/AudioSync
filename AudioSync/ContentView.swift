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
            Text(audioManager.hasBackingTrack ? "Has Backing Track" : "No Backing Track")
                .font(.headline)
                .padding()
            Button(action: {
                print("Clicked button")
                if audioManager.isRecording {
                    audioManager.stopRecording()
                } else {
                    audioManager.startRecording()
                }
            }, label: {
                if self.audioManager.isRecording {
                    Text("Stop Recording")
                } else {
                    Text("Start Recording")
                }
            })
            .disabled(buttonDisabled)
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
