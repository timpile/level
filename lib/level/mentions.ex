defmodule Level.Mentions do
  @moduledoc """
  The Mentions context.
  """

  import Ecto.Query

  alias Level.Posts.Post
  alias Level.Posts.Reply
  alias Level.Repo
  alias Level.Spaces.SpaceUser
  alias Level.Mentions.UserMention
  alias Level.Mentions.GroupedUserMention
  alias Level.Pubsub
  alias Level.Users.User

  # Suppress dialyzer warnings about dataloader functions
  @dialyzer {:nowarn_function, dataloader_data: 1}

  @behaviour Level.DataloaderSource

  defmacro aggregate_ids(column) do
    quote do
      fragment("array_agg(?) FILTER (WHERE ? IS NOT NULL)", unquote(column), unquote(column))
    end
  end

  @doc """
  The pattern for matching handles in a body of text.
  """
  def handle_pattern do
    ~r/
      (?:^|\W)                    # beginning of string or non-word char
      @((?>[a-z0-9][a-z0-9-]*))   # at-handle
      (?!\/)                      # without a trailing slash
      (?=
        \.+[ \t\W]|               # dots followed by space or non-word character
        \.+$|                     # dots at end of line
        [^0-9a-zA-Z_.]|           # non-word character except dot
        $                         # end of line
      )
    /ix
  end

  @doc """
  Builds a base query for fetching individual user mentions.
  """
  @spec base_query(SpaceUser.t()) :: Ecto.Query.t()
  def base_query(%SpaceUser{id: space_user_id}) do
    from m in UserMention,
      where: m.mentioned_id == ^space_user_id,
      where: is_nil(m.dismissed_at)
  end

  @doc """
  Builds a base query for fetching grouped user mentions.
  """
  @spec grouped_base_query(SpaceUser.t()) :: Ecto.Query.t()
  def grouped_base_query(%SpaceUser{id: space_user_id}) do
    from m in {"user_mentions", GroupedUserMention},
      where: m.mentioned_id == ^space_user_id,
      where: is_nil(m.dismissed_at),
      group_by: [m.mentioned_id, m.post_id],
      select: %{
        struct(m, [:post_id, :mentioned_id])
        | reply_ids: aggregate_ids(m.reply_id),
          mentioner_ids: aggregate_ids(m.mentioner_id),
          last_occurred_at: max(m.occurred_at),
          id: m.post_id
      }
  end

  @spec grouped_base_query(User.t()) :: Ecto.Query.t()
  def grouped_base_query(%User{id: user_id}) do
    from m in {"user_mentions", GroupedUserMention},
      join: su in assoc(m, :mentioned),
      where: su.user_id == ^user_id,
      where: is_nil(m.dismissed_at),
      group_by: [m.mentioned_id, m.post_id],
      select: %{
        struct(m, [:post_id, :mentioned_id])
        | reply_ids: aggregate_ids(m.reply_id),
          mentioner_ids: aggregate_ids(m.mentioner_id),
          last_occurred_at: max(m.occurred_at),
          id: m.post_id
      }
  end

  @doc """
  Record mentions from the body of a post.
  """
  @spec record(Post.t()) :: {:ok, [String.t()]}
  def record(%Post{space_user_id: author_id, body: body} = post) do
    do_record(body, post, nil, author_id)
  end

  @spec record(Post.t(), Reply.t()) :: {:ok, [String.t()]}
  def record(%Post{} = post, %Reply{id: reply_id, space_user_id: author_id, body: body}) do
    do_record(body, post, reply_id, author_id)
  end

  defp do_record(body, post, reply_id, author_id) do
    handle_pattern()
    |> Regex.run(body, capture: :all_but_first)
    |> process_handles(post, reply_id, author_id)
  end

  defp process_handles(nil, _, _, _) do
    {:ok, []}
  end

  defp process_handles(handles, post, reply_id, author_id) do
    lower_handles =
      handles
      |> Enum.map(fn handle -> String.downcase(handle) end)
      |> Enum.uniq()

    query =
      from su in SpaceUser,
        where: su.space_id == ^post.space_id,
        where: fragment("lower(?)", su.handle) in ^lower_handles,
        select: su.id

    query
    |> Repo.all()
    |> insert_batch(post, reply_id, author_id)
  end

  defp insert_batch(mentioned_ids, post, reply_id, author_id) do
    now = naive_now()

    params =
      Enum.map(mentioned_ids, fn mentioned_id ->
        %{
          space_id: post.space_id,
          post_id: post.id,
          reply_id: reply_id,
          mentioner_id: author_id,
          mentioned_id: mentioned_id,
          occurred_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(UserMention, params)
    {:ok, mentioned_ids}
  end

  @doc """
  Get and prepares the mentioner ids for a given grouped mention.
  """
  @spec mentioner_ids(GroupedUserMention.t()) :: [String.t()]
  def mentioner_ids(grouped_mention) do
    grouped_mention.mentioner_ids
    |> Enum.map(&Ecto.UUID.load/1)
    |> Enum.map(&map_loaded_uuid/1)
    |> Enum.reject(&is_nil/1)
  end

  defp map_loaded_uuid({:ok, value}), do: value
  defp map_loaded_uuid(_), do: nil

  @doc """
  Dismisses all mentions for given post id.
  """
  @spec dismiss_all(SpaceUser.t(), Post.t()) :: :ok | no_return()
  def dismiss_all(%SpaceUser{} = space_user, %Post{id: post_id} = post) do
    space_user
    |> base_query()
    |> where([m], m.post_id == ^post_id)
    |> exclude(:select)
    |> Repo.update_all(set: [dismissed_at: naive_now()])
    |> handle_dismiss_all(post)
  end

  defp handle_dismiss_all(_, %Post{id: post_id} = post) do
    Pubsub.publish(:mentions_dismissed, post_id, post)
    :ok
  end

  # Fetch the current time in `naive_datetime` format
  defp naive_now do
    DateTime.utc_now() |> DateTime.to_naive()
  end

  @impl true
  def dataloader_data(%{current_user: _user} = params) do
    Dataloader.Ecto.new(Repo, query: &dataloader_query/2, default_params: params)
  end

  def dataloader_data(_), do: raise("authentication required")

  @impl true
  def dataloader_query(GroupedUserMention, %{current_user: user}), do: grouped_base_query(user)
  def dataloader_query(_, _), do: raise("query not valid for this context")
end
