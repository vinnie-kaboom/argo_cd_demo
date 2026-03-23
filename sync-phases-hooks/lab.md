## 🎯 Lab Goal

Configure and deploy a `PreSync` hook using a Kubernetes `Job` to run a task _before_ the main application deployment begins.

## 📝 Overview & Concepts

Many applications require setup tasks, like database migrations, to run before the application itself is deployed. In this lab, you'll implement this pattern using an Argo CD `PreSync` hook. You will create a standard Kubernetes `Job` manifest within your Helm chart's `templates` directory. This `Job` will simulate a database migration by printing a message and pausing for a few seconds. By adding specific Argo CD annotations to this `Job`, you will instruct Argo CD to run it to completion during the `PreSync` phase, before it attempts to sync the main `Deployment` and `Service`.

## 📋 Lab Tasks

1.  In your repository fork, create a new manifest file under the `helm-guestbook` folder named `templates/presync-job.yaml`.
2.  Define a standard Kubernetes `Job` resource in this new file.
3.  The `Job`'s container should use a simple `busybox` image. Its command should print a message like "Running database migrations...", sleep for 10 seconds, and then exit successfully.
4.  Add the `argocd.argoproj.io/hook: PreSync` annotation to the `Job`'s metadata to assign it to the PreSync phase.
5.  Add the `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded` annotation to ensure the job is cleaned up after success and can be re-run on subsequent syncs.
6.  Commit and push the new `presync-job.yaml` manifest to your Git repository.
7.  In the Argo CD UI, manually trigger a `Sync` of your `guestbook` application.
8.  Observe the application's sync status and resource tree. Notice how the `Job` resource appears and runs first, and only after it succeeds do the `Deployment` and other resources sync.

## 📚 Helpful Resources

- [Argo CD - Resource Hooks](https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/)
- [Kubernetes `Job` Documentation](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Kubernetes Annotations](https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/)

## 💭 Reflection Questions

1. Why is it important to use `BeforeHookCreation` in the hook delete policy for jobs that run on every sync?
2. How does a `PreSync` hook differ from a standard `initContainer` in a Pod?
3. What happens to the main application deployment if the `PreSync` hook fails?