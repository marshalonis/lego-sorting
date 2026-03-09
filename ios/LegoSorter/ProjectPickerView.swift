import SwiftUI

struct ProjectPickerView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var api: APIService
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [Project] = []
    @State private var isLoading = true
    @State private var showCreate = false
    @State private var newProjectName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading projects…")
                } else if projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .navigationTitle("Select Project")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showCreate = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out", role: .destructive) { auth.logout() }
                }
            }
            .sheet(isPresented: $showCreate) {
                createSheet
            }
            .task { await loadProjects() }
        }
    }

    // MARK: - Subviews

    private var projectList: some View {
        List(projects) { project in
            Button(action: { api.currentProject = project; dismiss() }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                    Text("Created \(project.createdAt.prefix(10))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("No Projects Yet")
                .font(.title2.bold())
            Text("Create your first project to start organizing your LEGO collection.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
            Button("Create Project") { showCreate = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section("Project Name") {
                    TextField("e.g. My LEGO Collection", text: $newProjectName)
                        .autocorrectionDisabled()
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createProject() } }
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadProjects() async {
        isLoading = true
        projects = (try? await api.listProjects()) ?? []
        isLoading = false
    }

    private func createProject() async {
        isCreating = true
        errorMessage = nil
        do {
            let project = try await api.createProject(name: newProjectName.trimmingCharacters(in: .whitespaces))
            showCreate = false
            newProjectName = ""
            api.currentProject = project
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }
}

// MARK: - Project management sheet (used from DataView)

struct ProjectManagementView: View {
    @EnvironmentObject var api: APIService
    let project: Project

    @State private var members: [ProjectMember] = []
    @State private var showInvite = false
    @State private var inviteEmail = ""
    @State private var isInviting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Members") {
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.email).font(.subheadline)
                        Text("Added \(member.addedAt.prefix(10))").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Button("Invite by Email") { showInvite = true }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundColor(.red).font(.caption)
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMembers() }
        .alert("Invite Member", isPresented: $showInvite) {
            TextField("Email address", text: $inviteEmail)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { inviteEmail = "" }
            Button("Invite") { Task { await inviteMember() } }
        } message: {
            Text("The user must already have an account.")
        }
    }

    private func loadMembers() async {
        do {
            let proj = try await api.getProject(projectID: project.projectID)
            members = proj.members ?? []
        } catch {}
    }

    private func inviteMember() async {
        isInviting = true
        errorMessage = nil
        do {
            let member = try await api.addMember(projectID: project.projectID, email: inviteEmail)
            members.append(member)
            inviteEmail = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isInviting = false
    }
}
